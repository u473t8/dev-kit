#!/usr/bin/env bash
# End-to-end run of the flow scripts against GitHub itself (#40). The selftest fakes GitHub; this run shows
# what only GitHub can: that the board queries, the mutations and the gh commands still work.
#
# It acts on a sandbox repository and its own board, owned like the real board (kit-defaults.edn :board :owner),
# never on anything else, and checks every
# step against GitHub:
#   1. kit start files an issue: Status, Priority, Size and Showcase on the board, the branch on GitHub
#   2. a draft card with a title is converted to an issue by a second start
#   3. a commit; kit finish opens the pull request and the card is In review
#   4. the merge waits: without the owner's Approve the PR stays open (ADR-0003; the run never approves)
#   5. cleanup, also after a failure: the PR closed, the branches deleted, the issues closed as not planned and
#      their cards deleted, so the next run starts clean
# A failing step names itself and GitHub's answer.
#
#   test/e2e.sh        as the gh login in use: the agent's in a Claude session; in CI, the E2E_GH_TOKEN secret
#   test/e2e.sh --clean   removes the leftovers of interrupted runs started more than E2E_CLEAN_AGE seconds ago
#                      (default 1800; a run takes about 2 minutes), so a run in progress is never touched (#98)
# Environment: E2E_REPO (default shundeev/flow-sandbox), E2E_BOARD (the board's title, default "Flow sandbox").
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${E2E_REPO:-shundeev/flow-sandbox}"
BOARD="${E2E_BOARD:-Flow sandbox}"
# The sandbox board is owned where the real board is, a user's board with an organization's issues: the #22
# failure needs exactly that, and an organization's board would not show it.
read -r BOWNER REAL_NUM < <(bb -e '(let [b (:board (clojure.edn/read-string (slurp (str (first *command-line-args*)))))]
                                   (println (:owner b) (:number b)))' "$KIT/kit-defaults.edn")
RUN="e2e $(date -u +%Y-%m-%dT%H%M%SZ)-$$"
WORK="$(mktemp -d)"
STEP="setup"
issues=() branches=() pr=""

say() { echo "$*"; }
fail() { echo "FAIL  step $STEP: $*" >&2; exit 1; }
CLEAN=0
case "${1:-}" in
  "") ;;
  --clean) CLEAN=1 ;;
  *) fail "unknown argument $1: run test/e2e.sh, or test/e2e.sh --clean to remove old leftovers" ;;
esac

# Only the sandbox, never another repository or the real board (#40, invariant 2). The real board is
# recognised by its number, so that number must be known before anything else.
[[ -n "${BOWNER:-}" && "${REAL_NUM:-}" =~ ^[0-9]+$ ]] \
  || fail "the real board (:board :owner and :number) could not be read from $KIT/kit-defaults.edn with bb: install bb, or fix the file"
[[ "$REPO" == */flow-sandbox ]] || fail "E2E_REPO is $REPO: this run acts only on a */flow-sandbox repository"
[[ "$BOARD" != "Portfolio" ]] || fail "E2E_BOARD is the Portfolio board: this run acts only on the sandbox's own board"

gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1 \
  || fail "$REPO cannot be read as $(gh api user --jq .login 2>/dev/null || echo 'nobody'): the owner creates it and runs kit github on it (steps on dev-kit#40's PR)"
NUM="$(gh project list --owner "$BOWNER" --format json --jq ".projects[] | select(.title == \"$BOARD\") | .number" 2>&1 | head -1)"
[[ "$NUM" =~ ^[0-9]+$ ]] \
  || fail "no board \"$BOARD\" of $BOWNER visible ($NUM): the owner copies the Portfolio board for the sandbox (steps on dev-kit#40's PR)"
[ "$NUM" != "$REAL_NUM" ] || fail "board #$NUM of $BOWNER is the real board of kit-defaults.edn: this run never touches it"
SHOWCASE="$(gh project field-list "$NUM" --owner "$BOWNER" --format json --jq '.fields[] | select(.name == "Showcase") | .options[0].name // empty')" \
  || fail "the fields of board #$NUM could not be read (gh's answer above)"
[ -n "$SHOWCASE" ] || fail "the board \"$BOARD\" has no Showcase options: copy the Portfolio board, which has them"

export GHWF_OWNER="$BOWNER" GHWF_PROJECT_NUMBER="$NUM" GHWF_REPO="$REPO" GHWF_MERGE_WAIT=0

# One board item per issue: Status|Priority|Size|Showcase, or the draft's title for a draft.
# Every page of the board: a card just added is not among the last 100 of a long board.
all_items() {
  gh api graphql --paginate -f query='query($o:String!,$n:Int!,$endCursor:String){repositoryOwner(login:$o){... on ProjectV2Owner{projectV2(number:$n){
      items(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{
      id isArchived content{__typename ... on Issue{number title} ... on DraftIssue{title}}
      s:fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}
      p:fieldValueByName(name:"Priority"){... on ProjectV2ItemFieldSingleSelectValue{name}}
      z:fieldValueByName(name:"Size"){... on ProjectV2ItemFieldSingleSelectValue{name}}
      w:fieldValueByName(name:"Showcase"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}}' \
    -f o="$BOWNER" -F n="$NUM" --jq '.data.repositoryOwner.projectV2.items.nodes[]'
} # gh's error goes to stderr, into the log: the step that needed the board names GitHub's answer there
item() { all_items | jq -c 'select(.isArchived | not)'; }
branch_in() { sed -n 's/^\(Checked Out \)\{0,1\}Branch: //p' <<<"$1"; } # the start script's "Branch:" line
fields_of() { # fields_of <issue number>
  item | jq -r --argjson n "$1" 'select(.content.number == $n) | "\(.s.name)|\(.p.name)|\(.z.name)|\(.w.name)"' 2>/dev/null
}

cleanup() {
  local rc=$? problems=""
  STEP="5 cleanup"
  # What this run made is found by its label too, not only by what it noted: a step that dies halfway, after
  # GitHub made an issue, a branch or a PR, leaves nothing behind either.
  local slug prs heads open cards
  slug="$(tr '[:upper:] ' '[:lower:]-' <<<"$RUN" | tr -d ':')"
  # A list that cannot be read is a problem too: what it would have found stays behind.
  prs="$(gh pr list --repo "$REPO" --state open --json url,headRefName \
           --jq ".[] | select(.headRefName | contains(\"$slug\")) | .url")" || problems+=" (the open PRs could not be listed)"
  for p in $pr $prs; do
    gh pr close "$p" --repo "$REPO" --delete-branch >/dev/null 2>&1 || problems+=" PR $p;"
  done
  heads="$(gh api --paginate "repos/$REPO/branches?per_page=100" --jq ".[].name | select(contains(\"$slug\"))")" \
    || problems+=" (the branches could not be listed)"
  for b in "${branches[@]}" $heads; do
    gh api "repos/$REPO/git/refs/heads/$b" >/dev/null 2>&1 \
      && { gh api -X DELETE "repos/$REPO/git/refs/heads/$b" >/dev/null 2>&1 || problems+=" branch $b;"; }
  done
  open="$(gh issue list --repo "$REPO" --state open --limit 200 --json number,title \
            --jq ".[] | select(.title | startswith(\"$RUN\")) | .number")" || problems+=" (the open issues could not be listed)"
  for n in "${issues[@]}" $open; do
    [ "$(gh issue view "$n" --repo "$REPO" --json state --jq .state 2>/dev/null)" = OPEN ] || continue
    gh issue close "$n" --repo "$REPO" --reason "not planned" >/dev/null 2>&1 || problems+=" issue #$n;"
  done
  # Every card of this run, an issue's or a draft that was never converted.
  # Every card of this run, an issue's or a draft never converted, and cards of earlier runs left archived: deleted,
  # so the board stays short.
  cards="$(all_items | jq -r --arg r "$RUN" 'select((.content.title // "") as $t | ($t | startswith($r)) or (.isArchived and ($t | startswith("e2e ")))) | .id')" \
    || problems+=" (the board's cards could not be listed)"
  for id in $cards; do
    gh project item-delete "$NUM" --owner "$BOWNER" --id "$id" >/dev/null 2>&1 || problems+=" card $id;"
  done
  rm -rf "$WORK"
  if [ -n "$problems" ]; then
    echo "FAIL  step 5 cleanup: left in $REPO:$problems remove them by hand, then run again" >&2
    exit 1
  fi
  say "ok    5 cleanup: the PR closed, branches deleted, issues closed as not planned, cards deleted"
  exit "$rc"
}
# The labels ("e2e <time>-<pid>") of the runs started at least $1 seconds ago, from open issues, cards and branches.
old_labels() {
  local now titles cards names t
  now="$(date -u +%s)"
  titles="$(gh issue list --repo "$REPO" --state open --limit 200 --json title --jq '.[].title')" \
    && cards="$(all_items | jq -r '.content.title // empty')" \
    && names="$(gh api --paginate "repos/$REPO/branches?per_page=100" --jq '.[].name' \
                  | sed -nE 's/^.*e2e-([0-9]{4}-[0-9]{2}-[0-9]{2})t([0-9]{6})z-([0-9]+).*$/e2e \1T\2Z-\3/p')" \
    || fail "the issues, cards or branches of $REPO could not be listed (gh's answer above): check gh auth status"
  printf '%s\n' "$titles" "$cards" "$names" | { grep -oE '^e2e [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-[0-9]+' || true; } | sort -u \
    | while IFS= read -r l; do
        t="${l#e2e }"; t="${t%-*}"
        t="$(date -u -d "${t:0:10} ${t:11:2}:${t:13:2}:${t:15:2}" +%s 2>/dev/null)" || continue
        if [ $((now - t)) -ge "$1" ]; then echo "$l"; fi
      done
}

if [ "$CLEAN" = 1 ]; then # each old run is cleaned as the run itself cleans up after a failure
  STEP="clean"; age="${E2E_CLEAN_AGE:-1800}"; rc=0
  [[ "$age" =~ ^[0-9]+$ ]] || fail "E2E_CLEAN_AGE is $age, not a number of seconds: unset it or set e.g. 1800"
  labels="$(old_labels "$age")" || exit 1
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    say "clean: $l"; (RUN="$l"; cleanup) || rc=1
  done <<<"$labels"
  [ "$rc" = 0 ] && say "ok    clean: $REPO has no e2e leftovers older than $((age / 60)) minutes"
  rm -rf "$WORK"; exit "$rc"
fi
trap cleanup EXIT

say "e2e: $REPO, board \"$BOARD\" (#$NUM), as $(gh api user --jq .login), run \"$RUN\""

STEP="setup"
gh repo clone "$REPO" "$WORK/repo" -- -q 2>&1 || fail "cloning $REPO failed"
cd "$WORK/repo" || fail "no clone"
git config user.name "dev-kit e2e"
git config user.email "e2e@users.noreply.github.com"
git config credential.helper '!gh auth git-credential'

STEP="1 start files an issue"
out="$(bb "$KIT/bin/kit" start --title "$RUN: task" --priority Low --size XS --showcase "$SHOWCASE" \
         --status "In progress" 2>&1)" || fail "$out"
n1="$(sed -n 's/^Issue Number: //p' <<<"$out")"; b1="$(branch_in "$out")"
[ -n "$n1" ] && issues+=("$n1"); [ -n "$b1" ] && branches+=("$b1") # cleaned up whatever follows
[ -n "$n1" ] && [ -n "$b1" ] || fail "no issue number or branch in: $out"
got="$(fields_of "$n1")"
[ "$got" = "In progress|Low|XS|$SHOWCASE" ] || fail "the card of #$n1 reads \"$got\", not \"In progress|Low|XS|$SHOWCASE\""
gh api "repos/$REPO/branches/$b1" --jq .name >/dev/null 2>&1 || fail "branch $b1 is not on GitHub"
[ "$(git branch --show-current)" = "$b1" ] || fail "the clone is on $(git branch --show-current), not $b1"
say "ok    1 start: #$n1 on the board as In progress|Low|XS|$SHOWCASE; branch $b1 on GitHub and checked out"

STEP="2 a draft card is converted"
gh project item-create "$NUM" --owner "$BOWNER" --title "$RUN: draft" >/dev/null 2>&1 || fail "the draft card could not be created"
# A card just created reaches the board's item list a moment later; the owner's drafts are older than that.
for _ in $(seq 20); do
  [ -n "$(item | jq -r --arg t "$RUN: draft" 'select(.content.title == $t) | .id' 2>/dev/null)" ] && break
  sleep 2
done
out="$(bb "$KIT/bin/kit" start --title "$RUN: draft" --priority Low --size XS --showcase "$SHOWCASE" \
         --no-checkout 2>&1)" || fail "$out"
n2="$(sed -n 's/^Issue Number: //p' <<<"$out")"; b2="$(branch_in "$out")"
[ -n "$n2" ] && issues+=("$n2"); [ -n "$b2" ] && branches+=("$b2")
[ -n "$n2" ] || fail "no issue number in: $out"
left="$(item | jq -r --arg t "$RUN: draft" 'select(.content.__typename == "DraftIssue" and .content.title == $t) | .id' 2>/dev/null)"
[ -z "$left" ] || fail "the draft card is still a draft ($left) after the start"
[ -n "$(fields_of "$n2")" ] || fail "#$n2 has no card on the board"
say "ok    2 draft: the card became issue #$n2, the draft is gone"

STEP="3 finish opens the pull request"
echo "$RUN" > e2e.txt
cat > "$WORK/body.md" <<EOF
## What changed
- e2e.txt, written by dev-kit's end-to-end run.

## Why
dev-kit#40: the flow scripts, run against GitHub.

## Root causes
none beyond the issue

## Review
none: a sandbox run.

## User-level test
The run itself.

## Verified
- the run's own checks

## Not verified
- the merge, which waits for the owner

## Owner steps
none

ADR: none
EOF
out="$(bb "$KIT/bin/kit" finish --type test --summary "end-to-end run $RUN" --add e2e.txt \
         --pr-body-file "$WORK/body.md" 2>&1)" || fail "$out"
pr="$(sed -n 's/^PR URL: //p' <<<"$out")"
[ -n "$pr" ] || fail "no PR URL in: $out"
[ "$(gh pr view "$pr" --json state --jq .state 2>&1)" = OPEN ] || fail "the PR $pr is not open"
got="$(fields_of "$n1")"
[ "${got%%|*}" = "In review" ] || fail "the card of #$n1 reads \"$got\", not In review"
say "ok    3 finish: $pr open, the card In review"

STEP="4 the merge waits for the owner"
out="$(bb "$KIT/bin/kit" merge 2>&1)" && fail "kit merge succeeded without the owner's Approve: $out"
grep -q "Waiting for the owner's Approve" <<<"$out" || fail "the merge stopped for another reason: $out"
[ "$(gh pr view "$pr" --json state --jq .state 2>&1)" = OPEN ] || fail "the PR $pr is no longer open"
say "ok    4 merge: refused without the owner's Approve, $pr still open"
