#!/usr/bin/env bash
# End-to-end check of dev-kit on a throwaway project: init, doctor, repairs, modules,
# the git and Claude Code hooks, and the offline guards of the flow scripts.
#
#   test/selftest.sh            uses the working tree of this dev-kit checkout
#
# Needs: git, bb, jq; zprint for the pre-commit case (skipped when absent).
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  ok    $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/        /'; }
expect_exit() { # expect_exit <code> <name> <cmd...>
  local want="$1" name="$2"; shift 2
  local out code
  out="$("$@" 2>&1)"; code=$?
  if [ "$code" -eq "$want" ]; then ok "$name"; else bad "$name (exit $code, want $want)" "$out"; fi
  LAST="$out"
}
contains() { # contains <name> <needle> <haystack>
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing: $2"; fi
}

export GIT_AUTHOR_NAME=selftest GIT_AUTHOR_EMAIL=selftest@example.invalid
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@example.invalid
# doctor checks the GitHub identity only inside a Claude session; the cases that test it set
# CLAUDECODE themselves, so a selftest run from a session judges nothing about that session.
unset CLAUDECODE GH_TOKEN GITHUB_TOKEN
# The flow scripts read GHWF_* from the session's settings; a run from a session must not see
# them, as CI does not (#55).
while read -r v; do unset "$v"; done < <(compgen -e | grep '^GHWF_')
# The machine's global git config and ignore file stay out, as in CI: Claude Code puts
# settings.local.json into the global ignore file, which would hide what kit itself ignores.
: > "$WORK/gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" XDG_CONFIG_HOME="$WORK/config"
# A home of its own: whether the agent is logged in on this machine must not change the results.
export HOME="$WORK/home"
mkdir -p "$HOME"
# The person behind the agent on this "machine": their own gh login, not the agent's (#52).
mkdir -p "$XDG_CONFIG_HOME/gh" && printf 'github.com:\n    user: the-human\n' > "$XDG_CONFIG_HOME/gh/hosts.yml"

echo "dev-kit selftest ($KIT)"

# A project with dev-kit mounted at .shared. The submodule is cloned from this checkout's
# HEAD, then the working tree is laid over it so uncommitted changes are what gets tested.
P="$WORK/project"
git init -q -b main "$P"
cd "$P" || exit 1
git remote add origin https://github.com/u473t8/kit-selftest.git
git -c protocol.file.allow=always submodule add -q "$KIT" .shared
(cd "$KIT" && tar --exclude=.git -cf - .) | (cd .shared && tar -xf -)
git commit -qm "chore: add dev-kit"
kit=".shared/bin/kit"

echo "- empty project"
expect_exit 1 "doctor fails without kit.edn" bb $kit doctor
contains "doctor names the missing kit.edn" "kit.edn is missing" "$LAST"

echo "- init"
expect_exit 0 "init succeeds" bb $kit init --showcase Site
contains "init reports what it wrote" "wrote .claude/settings.json" "$LAST"
grep -q ':repo     "u473t8/kit-selftest"' kit.edn && ok "kit.edn infers repo from origin" || bad "kit.edn repo" "$(cat kit.edn)"
[ "$(jq -r .env.GHWF_REPO .claude/settings.json)" = "u473t8/kit-selftest" ] && ok "settings env carries the repo" || bad "settings env"
[ "$(jq -r .env.GHWF_PROJECT_NUMBER .claude/settings.json)" = "3" ] && ok "settings env carries the board from defaults" || bad "board number"
[ "$(jq -r .env.GHWF_REVIEWERS .claude/settings.json)" = "shundeev/owners" ] && ok "settings env names the reviewers from :owners" || bad "GHWF_REVIEWERS"
[ "$(jq -r .env.GHWF_HUMAN .claude/settings.local.json)" = "the-human" ] && ok "the per-machine settings name the person behind the agent" || bad "GHWF_HUMAN" "$(cat .claude/settings.local.json)"
[ -f .claude/skills/repo-task-delivery/SKILL.md ] && ok "skill readable through its link" || bad "skill link"
grep -q "Managed by dev-kit" .claude/agents/ops.md && ok "agent copied with the managed marker" || bad "agent copy"
head -1 .claude/agents/ops.md | grep -qx -- '---' && ok "agent copy keeps frontmatter first" || bad "agent frontmatter"
[ -f LICENSE ] && grep -q "MIT License" LICENSE && ok "LICENSE scaffolded" || bad "LICENSE"
[ -f .github/workflows/ci.yml ] && ok "CI workflow written" || bad "ci.yml"
[ "$(git config core.hooksPath)" = ".shared/githooks" ] && ok "hooksPath set" || bad "hooksPath"
grep -q "dev-kit:begin" AGENTS.md && grep -q "# This project" AGENTS.md && ok "AGENTS.md has the block and the project part" || bad "AGENTS.md"
[ ! -e CLAUDE.md ] && ok "no CLAUDE.md" || bad "CLAUDE.md exists"
[ ! -e README.md ] && ok "README not scaffolded without --scaffold" || bad "README scaffolded"

echo "- permissions"
perm() { jq -r --arg list "$1" '.permissions[$list][]' .claude/settings.json; }
has() { perm "$1" | grep -qxF -- "$2"; }
for rule in "Bash(git *)" "Bash(gh *)" "Bash(bb *)"; do
  has allow "$rule" && bad "no blanket allow: $rule" || ok "no blanket allow: $rule"
done
# kit merge runs without a prompt: the server merges only on the owner's Approve (#22, #37, #95).
has allow "Bash(.shared/bin/kit *)" && has allow "Bash(bb .shared/bin/kit *)" \
  && ! perm ask | grep -q 'kit merge' \
  && ok "kit merge runs without a prompt" || bad "kit merge asks, or kit is not allowed"
has ask "Bash(gh pr merge *)" && ok "asks: Bash(gh pr merge *)" || bad "asks: Bash(gh pr merge *)"
# #20: the safety guard refuses these outright; an ask rule would never be reached
for rule in "Bash(git reset --hard *)" "Bash(git clean *)" "Bash(git branch -D *)" "Bash(git checkout -- *)" "Bash(git restore *)"; do
  has ask "$rule" && bad "still asks: $rule" || ok "no ask rule, the safety guard decides: $rule"
done
# #74: closing an issue reopens in one click and happens on the owner's word or from the flow scripts.
if has ask "Bash(gh issue close *)"; then bad "closing an issue still asks the owner"; else ok "closing an issue does not ask"; fi
for rule in "Bash(git push --force *)" "Bash(git push * --force *)" "Bash(git push * --force)" "Bash(git push -f *)" \
            "Bash(git push * -f)" "Bash(git push * +*)" "Bash(gh repo delete *)"; do
  has deny "$rule" && ok "denies: $rule" || bad "denies: $rule"
done
has allow "Bash(.shared/bin/kit *)" && ok "kit path substituted" || bad "kit path substituted"
# #30: the project-link plugin comes from the pinned submodule, with nothing to install by hand
jq -e '.extraKnownMarketplaces["dev-kit"].source == {source: "directory", path: ".shared"} and .enabledPlugins["project-link@dev-kit"] == true' \
  .claude/settings.json >/dev/null && ok "settings enable project-link from the .shared marketplace" || bad "plugin settings" "$(jq -c '{extraKnownMarketplaces, enabledPlugins}' .claude/settings.json)"
mk="$KIT/.claude-plugin/marketplace.json"
jq -r '.plugins[] | "\(.name) \(.source)"' "$mk" | while read -r name src; do
  [ "$(jq -r .name "$KIT/$src/.claude-plugin/plugin.json" 2>/dev/null)" = "$name" ] && echo ok || echo "bad $name"
done | grep -q bad && bad "a marketplace entry does not match its plugin.json" \
  || { [ "$(jq '.plugins | length' "$mk" 2>/dev/null || echo 0)" -ge 1 ] && ok "marketplace entries match their plugins" || bad "no plugins in $mk"; }
if command -v claude >/dev/null 2>&1 && [ -z "${CI:-}" ]; then
  out="$(claude plugin validate "$KIT" 2>&1)" && ok "claude plugin validate passes for dev-kit's marketplace" || bad "claude plugin validate" "$out"
fi
jq -e '.hooks.PreToolUse and .hooks.SessionStart' .claude/settings.json >/dev/null && ok "hooks survive the settings merge" || bad "hooks lost in the settings merge"
perm allow | grep -q '{{kit}}' && bad "unsubstituted {{kit}}" || ok "no {{kit}} placeholder left"
has allow "Bash(clj-kondo *)" && bad "clojure allows without the module" || ok "no clojure allows without the module"
own="$KIT/.claude/settings.json"; base="$KIT/claude/settings.base.json"
for list in ask deny; do
  [ "$(jq -c ".permissions.$list" "$own")" = "$(jq -c ".permissions.$list" "$base")" ] \
    && ok "dev-kit's own $list rules match the base" || bad "dev-kit's own $list rules drifted from the base"
done

echo "- idempotence"
expect_exit 0 "second init succeeds" bb $kit init
contains "second init changes nothing" "nothing to change" "$LAST"
git check-ignore -q .claude/worktrees/x/y && ok "init: .claude/worktrees/ is git-ignored (site#14)" || bad "init: worktrees not ignored"
[ "$(grep -c 'claude/worktrees' "$(git rev-parse --git-path info/exclude)")" = 1 ] && ok "  once, after two inits" || bad "  not once"
expect_exit 0 "doctor passes" bb $kit doctor
touch .shared/stray-file
expect_exit 0 "local edits in dev-kit only warn" bb $kit doctor
contains "doctor warns about local edits in .shared" "WARN  .shared has local changes" "$LAST"
rm .shared/stray-file

echo "- repairs"
echo '{}' > .claude/settings.json
expect_exit 1 "doctor catches an edited settings.json" bb $kit doctor
contains "doctor names the file" ".claude/settings.json: differs" "$LAST"
printf '\nProject note that must survive.\n' >> AGENTS.md
sed -i 's/^# Working rules$/# Working rules (edited by hand)/' AGENTS.md
expect_exit 1 "doctor catches an edited dev-kit block" bb $kit doctor
rm .claude/skills/adr
expect_exit 0 "init repairs everything" bb $kit init
grep -q "Project note that must survive." AGENTS.md && ok "project text outside the block survives" || bad "project text lost"
grep -q "^# Working rules$" AGENTS.md && ok "block restored" || bad "block not restored"
[ -L .claude/skills/adr ] && ok "skill link restored" || bad "skill link"
git config --unset core.hooksPath
expect_exit 1 "doctor catches a missing hooksPath" bb $kit doctor
expect_exit 0 "doctor --ci skips local git config" bb $kit doctor --ci
bb $kit init >/dev/null

echo "- init converges, validates kit.edn, keeps project files (#14)"
fresh() { # fresh <dir>: a new project with dev-kit mounted, no kit.edn; cd into it
  git init -q -b main "$1" && cd "$1" || exit 1
  git remote add origin https://github.com/u473t8/kit-selftest.git
  git -c protocol.file.allow=always submodule add -q "$KIT" .shared
  (cd "$KIT" && tar --exclude=.git -cf - .) | (cd .shared && tar -xf -)
  git commit -qm "chore: add dev-kit"
}
blocks() { echo "$(grep -c '^<!-- dev-kit:begin' AGENTS.md)/$(grep -c '^<!-- dev-kit:end' AGENTS.md)"; }

fresh "$WORK/m1"; bb $kit init --showcase Site >/dev/null 2>&1
cat AGENTS.md AGENTS.md > "$WORK/a" && mv "$WORK/a" AGENTS.md
expect_exit 0 "init: a duplicated block becomes one" bb $kit init
[ "$(blocks)" = 1/1 ] && ok "  one begin, one end" || bad "  markers" "$(grep -n 'dev-kit:' AGENTS.md)"
grep -q "# This project" AGENTS.md && ok "  the project part is kept" || bad "  project part lost"
expect_exit 0 "  doctor passes" bb $kit doctor --ci
sed -i 's/Edit it in dev-kit, not here\./Do not edit by hand./' AGENTS.md
expect_exit 0 "init: a begin marker in another wording is still found" bb $kit init
[ "$(blocks)" = 1/1 ] && ok "  still one block" || bad "  markers" "$(grep -n 'dev-kit:' AGENTS.md)"
sed -i 's/$/\r/' AGENTS.md
expect_exit 0 "init: an AGENTS.md with CRLF line ends" bb $kit init
[ "$(grep -vc $'\r$' AGENTS.md)" = 0 ] && ok "  keeps CRLF on every line" || bad "  mixed line ends" "$(grep -vn $'\r$' AGENTS.md | head -3)"
expect_exit 0 "  a rerun" bb $kit init
contains "  changes nothing" "nothing to change" "$LAST"
sed -i 's/\r$//' AGENTS.md; bb $kit init >/dev/null 2>&1
sed -i '/^<!-- dev-kit:begin/d' AGENTS.md; cp AGENTS.md "$WORK/agents-before"
expect_exit 1 "init: an end marker without its begin is refused" bb $kit init
contains "  names the line" "AGENTS.md: line" "$LAST"
[ "$(grep -c 'AGENTS.md: line' <<<"$LAST")" = 1 ] && ! grep -q "nothing to change" <<<"$LAST" \
  && ok "  once, and not after 'nothing to change'" || bad "  output" "$LAST"
cmp -s AGENTS.md "$WORK/agents-before" && ok "  AGENTS.md is left as it was" || bad "  AGENTS.md changed" "$(grep -n 'dev-kit:' AGENTS.md)"
expect_exit 1 "  doctor fails the same way" bb $kit doctor --ci
contains "  with the line" "AGENTS.md: line" "$LAST"

fresh "$WORK/v1"
expect_exit 1 "init: without --showcase it is refused" bb $kit init
contains "  names the flag" "--showcase" "$LAST"
[ ! -e kit.edn ] && ok "  no kit.edn written" || bad "  kit.edn written" "$(cat kit.edn)"
expect_exit 1 "init: an unknown module is refused" bb $kit init --showcase Site --modules Clojure
contains "  lists the known ones" "known modules: clojure" "$LAST"
[ ! -e kit.edn ] && ok "  no kit.edn written" || bad "  kit.edn written" "$(cat kit.edn)"
expect_exit 0 "init: --modules \"\" means none" bb $kit init --showcase Site --modules ""
grep -q ':modules  #{}' kit.edn && ok "  kit.edn is readable, with no modules" || bad "  kit.edn" "$(cat kit.edn)"
sed -i 's/ :showcase "Site"/ :showcase nil/' kit.edn
expect_exit 1 "doctor: a kit.edn without :showcase fails" bb $kit doctor --ci
contains "  names the key" ":showcase" "$LAST"
sed -i 's/ :showcase nil/ :showcase "Site"/; s/:modules  #{}/:modules  #{:Clojure}/' kit.edn
expect_exit 1 "doctor: an unknown module in kit.edn fails" bb $kit doctor --ci
contains "  names it" ":Clojure" "$LAST"
sed -i 's/#{:Clojure}/#{}/; s/^{:repo/{:agent {:login "other"}\n :repo/' kit.edn
expect_exit 1 "doctor: a partial :agent fails instead of mixing two accounts" bb $kit doctor --ci
contains "  names what is missing" ":email" "$LAST"
sed -i 's/^{:agent {:login "other"}/{:board {:number 7}/' kit.edn
bb $kit init >/dev/null 2>&1
[ "$(jq -r '.env.GHWF_OWNER + " " + .env.GHWF_PROJECT_NUMBER' .claude/settings.json)" = "u473t8 7" ] \
  && ok "init: a partial :board keeps the default owner" || bad "partial :board" "$(jq -c .env .claude/settings.json)"
printf '{:repo "a/b"\n :x ]\n}\n' > kit.edn
expect_exit 1 "doctor: an unreadable kit.edn fails with where" bb $kit doctor --ci
contains "  names the file and the line" "kit.edn line 2" "$LAST"
grep -qE "Exception|----- Error" <<<"$LAST" && bad "  a stack trace" "$LAST" || ok "  no stack trace"

for c in "empty:" "comment-only:;; project linters come later"; do
  fresh "$WORK/k-${c%%:*}"; mkdir -p .clj-kondo; printf '%s\n' "${c#*:}" > .clj-kondo/config.edn
  expect_exit 0 "init: a clj-kondo config that is ${c%%:*} becomes the map" bb $kit init --showcase Site --modules clojure
  bb -e '(assert (= ["../.shared/clojure/clj-kondo"] (:config-paths (clojure.edn/read-string (slurp ".clj-kondo/config.edn")))))' \
    2>/dev/null && ok "  with :config-paths" || bad "  config" "$(cat .clj-kondo/config.edn)"
done
grep -q "project linters come later" .clj-kondo/config.edn && ok "  the comment is kept" || bad "  comment lost"
fresh "$WORK/k-vector"; mkdir -p .clj-kondo; echo '[]' > .clj-kondo/config.edn
expect_exit 1 "init: a clj-kondo config that is not a map fails that item" bb $kit init --showcase Site --modules clojure
contains "  says to make it a map" "make it a map" "$LAST"
[ "$(git config --local core.hooksPath)" = ".shared/githooks" ] && ok "  the other items still ran" || bad "  hooksPath unset"

fresh "$WORK/c1"; bb $kit init --showcase Site >/dev/null 2>&1
echo "# mine" > CLAUDE.md
expect_exit 1 "doctor: a CLAUDE.md that hides AGENTS.md fails" bb $kit doctor --ci
contains "  says what to do" "move its content into AGENTS.md" "$LAST"
rm CLAUDE.md; echo "# mine" > CLAUDE.local.md
expect_exit 1 "doctor: so does a CLAUDE.local.md" bb $kit doctor
rm CLAUDE.local.md; echo "# above" > "$WORK/CLAUDE.md"
expect_exit 1 "doctor: and a CLAUDE.md in a folder above the project" bb $kit doctor
contains "  names it" "$WORK/CLAUDE.md" "$LAST"
expect_exit 0 "  doctor --ci looks only at the project's own files" bb $kit doctor --ci
mkdir -p "$HOME/.claude"
echo '{"pluginConfigs":{"cc-plugin-agents-md@builtin":{"options":{"instructionFiles":"claude-md-and-agents-md"}}}}' > "$HOME/.claude/settings.json"
expect_exit 0 "doctor: unless Claude Code is set to read both" bb $kit doctor
rm "$HOME/.claude/settings.json" "$WORK/CLAUDE.md"
fresh "$HOME/proj"; bb $kit init --showcase Site >/dev/null 2>&1; echo "# user" > "$HOME/.claude/CLAUDE.md"
expect_exit 0 "doctor: the user's own ~/.claude/CLAUDE.md does not count" bb $kit doctor
ln -s "$HOME" "$WORK/home-link"
out="$(env HOME="$WORK/home-link" bb $kit doctor 2>&1)"
grep -q "hides AGENTS.md" <<<"$out" && bad "  HOME through a link: flagged" "$out" || ok "  nor when HOME is reached through a link"
rm "$HOME/.claude/CLAUDE.md"

fresh "$WORK/r0"; bb $kit init --showcase Site >/dev/null 2>&1; mv kit.edn "$WORK/kit.edn.r0"
expect_exit 0 "init: without kit.edn again, dev-kit's own settings.json is not taken as the project's" bb $kit init --showcase Site
grep -q ":claude-settings" kit.edn && bad "  folded into kit.edn" "$(head -c 300 kit.edn)" || ok "  kit.edn has no :claude-settings"

fresh "$WORK/r1"; mkdir -p .claude/agents .github/workflows
echo '{"permissions":{"allow":["Bash(make *)"]}}' > .claude/settings.json
printf 'name: mine\non: push\njobs: {}\n' > .github/workflows/ci.yml
printf -- '---\nname: ops\n---\nmy own ops agent\n' > .claude/agents/ops.md
git config --local core.hooksPath .husky
expect_exit 1 "init: project files where dev-kit writes are refused" bb $kit init --showcase Site
for f in .github/workflows/ci.yml .claude/agents/ops.md core.hooksPath "move it away" "rename it" "git config --unset core.hooksPath"; do contains "  names: $f" "$f" "$LAST"; done
[ ! -e kit.edn ] && grep -q "name: mine" .github/workflows/ci.yml && grep -q "my own ops" .claude/agents/ops.md \
  && [ "$(git config --local core.hooksPath)" = .husky ] && ok "  nothing is written" || bad "  something was written"
mv .github/workflows/ci.yml .github/workflows/project.yml; mv .claude/agents/ops.md .claude/agents/my-ops.md
git config --local --unset core.hooksPath
expect_exit 0 "init: after the moves it goes through" bb $kit init --showcase Site
contains "  says where the settings went" ":claude-settings" "$LAST"
jq -e '.permissions.allow | index("Bash(make *)")' .claude/settings.json >/dev/null && ok "  the project's permission is kept" || bad "  permission lost"
grep -qF 'Bash(make *)' kit.edn && ok "  and lives in kit.edn" || bad "  kit.edn" "$(cat kit.edn)"
expect_exit 0 "  a rerun" bb $kit init
contains "  changes nothing" "nothing to change" "$LAST"
cd "$P" || exit 1

echo "- code owners"
[ "$(grep -v '^#' .github/CODEOWNERS)" = "* @shundeev/owners" ] && ok "CODEOWNERS makes the owners team review every file" || bad "CODEOWNERS" "$(cat .github/CODEOWNERS 2>&1)"
grep -qx '\* @shundeev/owners' "$KIT/.github/CODEOWNERS" && ok "dev-kit itself has the same code owner" || bad "dev-kit's own CODEOWNERS"
echo '* @someone-else' > .github/CODEOWNERS
expect_exit 1 "doctor --ci catches an edited CODEOWNERS" bb $kit doctor --ci
contains "doctor names CODEOWNERS" ".github/CODEOWNERS: differs" "$LAST"
expect_exit 1 "init does not overwrite a CODEOWNERS without dev-kit's marker (#14)" bb $kit init
contains "  names it" ".github/CODEOWNERS holds a file dev-kit did not write" "$LAST"
rm .github/CODEOWNERS
cp kit.edn "$WORK/kit.edn.bak"
owners() { bb -e "(spit \"kit.edn\" (pr-str (assoc (clojure.edn/read-string (slurp \"kit.edn\")) :owners $1)))"; }
owners '["kit-owner" "colleague"]'
bb $kit init >/dev/null
[ "$(grep -v '^#' .github/CODEOWNERS)" = "* @kit-owner @colleague" ] && ok "every code owner from kit.edn is listed; any one approval counts" || bad "owners override" "$(cat .github/CODEOWNERS)"
owners '[]'
expect_exit 1 "init refuses a project without code owners" bb $kit init
contains "and says what to put in kit.edn" ":owners must list who reviews every change" "$LAST"
mv "$WORK/kit.edn.bak" kit.edn
bb $kit init >/dev/null

echo "- issue form and PR template"
form=.github/ISSUE_TEMPLATE/task.yml
prt=.github/pull_request_template.md
[ -f $form ] && [ -f $prt ] && ok "init writes the issue form and the PR template" || bad "templates missing"
labels="$(bb -e "(require '[clj-yaml.core :as y]) (doseq [f (:body (y/parse-string (slurp \"$form\")))] (when-let [l (get-in f [:attributes :label])] (println (str l (when (get-in f [:validations :required]) \" (required)\")))))" 2>&1)"
[ "$labels" = "$(printf 'Requirements (required)\nInvariants\nDesign\nPlan\nDone when (required)')" ] \
  && ok "the issue form has the five ADR-0002 sections; Requirements and Done when are required" || bad "issue form sections" "$labels"
missing=""
for s in "## What changed" "## Why" "## Root causes" "## Review" "## User-level test" "## Verified" "## Not verified" "## Owner steps"; do
  grep -qx -- "$s" $prt || missing="$missing, $s"
done
[ -z "$missing" ] && ok "the PR template has the sections the owner reviews" || bad "PR template lacks${missing#,}"
grep -Eq '^ADR: +[^[:space:]]' $prt && ok "the PR template passes the finish script's ADR check" || bad "PR template ADR line"
if grep -Eqi '(close[sd]?|fix(e[sd])?|resolve[sd]?) #' $prt; then bad "PR template carries a closing keyword (the finish script adds it)"
else ok "the PR template leaves the closing keyword to the finish script"; fi
for f in $form $prt; do cmp -s "$f" "$KIT/$f" && ok "dev-kit itself has the same $f" || bad "dev-kit's own $f differs"; done
echo "# edited" >> $prt
expect_exit 1 "doctor --ci catches an edited PR template" bb $kit doctor --ci
contains "doctor names the template" "$prt: differs" "$LAST"
bb $kit init >/dev/null

echo "- delivery skill"
skill="$KIT/claude/skills/repo-task-delivery/SKILL.md"
sed -n 2p "$skill" | grep -qx 'name: repo-task-delivery' && ok "the delivery skill names itself" || bad "skill frontmatter"
missing=""
for h in "Size sets the ceremony" "Requirements" "Invariants" "Design" "G1" "Plan and execute" "Review and simplify" \
         "User-level test" "Pull request" "Merge" "Retrospective"; do
  grep -Eqi "^## [0-9]+\. .*$h" "$skill" || missing="$missing, $h"
done
[ -z "$missing" ] && ok "the delivery skill walks every stage of ADR-0002" || bad "the skill lacks the stage${missing#,}"
[ "$(wc -l < "$KIT/rules/shared.md")" -le 100 ] && ok "the rules block stays within 100 lines" || bad "rules/shared.md is $(wc -l < "$KIT/rules/shared.md") lines"
missing=""
for phrase in "what changed for them and what is needed from them" "ends with the pull request's link" \
              "as numbered steps" "says what to do" "not only into an agent's memory"; do
  grep -qF -- "$phrase" "$KIT/rules/shared.md" || missing="$missing; $phrase"
done
[ -z "$missing" ] && ok "the owner's standing rules are in the rules block" || bad "rules block lacks:${missing#;}"

echo "- agent identity: per-machine settings"
default_login="$(bb -e '(println (get-in (clojure.edn/read-string (slurp ".shared/kit-defaults.edn")) [:agent :login]))')"
local=.claude/settings.local.json
lenv() { jq -r --arg k "$1" '.env[$k]' "${2:-$local}"; }
[ "$(lenv GH_CONFIG_DIR)" = "$HOME/.config/gh-agent" ] && ok "gh in sessions reads the agent's config" || bad "local GH_CONFIG_DIR" "$(cat $local 2>&1)"
[ "$(lenv GIT_CONFIG_KEY_0)=$(lenv GIT_CONFIG_VALUE_0)" = "url.https://github.com/.insteadOf=git@github.com:" ] \
  && ok "SSH remotes go over HTTPS in sessions" || bad "insteadOf"
jq -e '.env.GIT_CONFIG_COUNT == "3" and .env.GIT_CONFIG_VALUE_1 == ""' $local >/dev/null \
  && ok "inherited github.com credential helpers are reset" || bad "helper reset"
[ "$(lenv GIT_CONFIG_VALUE_2)" = '!gh auth git-credential' ] && ok "git push authenticates through gh" || bad "credential helper"
[ "$(lenv GIT_AUTHOR_NAME)" = "$default_login" ] && [ "$(lenv GIT_COMMITTER_NAME)" = "$default_login" ] \
  && ok "commits are made by the agent" || bad "author"
git check-ignore -q $local && ok "settings.local.json is git-ignored" || bad "settings.local.json is not ignored"
jq '.permissions.allow = ["Bash(ls *)"] | .env.MY_VAR = "1" | .env.GH_CONFIG_DIR = "/elsewhere"' $local > "$WORK/local.json"
mv "$WORK/local.json" $local
expect_exit 1 "doctor catches a changed agent env" bb $kit doctor
contains "doctor names settings.local.json" "$local: env differs" "$LAST"
expect_exit 0 "init restores the agent env" bb $kit init
jq -e '.permissions.allow == ["Bash(ls *)"] and .env.MY_VAR == "1"' $local >/dev/null \
  && ok "init keeps the owner's own local settings" || bad "local settings lost" "$(cat $local)"
[ "$(lenv GH_CONFIG_DIR)" = "$HOME/.config/gh-agent" ] && ok "agent env restored" || bad "agent env not restored"
sed -i '\#^/.claude/settings.local.json$#d' .git/info/exclude
expect_exit 1 "doctor catches settings.local.json that git would commit" bb $kit doctor
contains "doctor says why" "$local: is not git-ignored" "$LAST"
rm $local
expect_exit 0 "doctor --ci skips the per-machine settings" bb $kit doctor --ci
echo '{}' > .claude/settings.json
git config --unset core.hooksPath
expect_exit 0 "init --local succeeds" bb $kit init --local
git check-ignore -q $local && [ -f $local ] && ok "init --local writes and ignores settings.local.json" || bad "not restored"
[ "$(git config core.hooksPath)" = ".shared/githooks" ] && ok "init --local sets the hooks path" || bad "hooksPath not restored"
[ "$(cat .claude/settings.json)" = "{}" ] && ok "init --local leaves committed files alone" || bad "init --local touched settings.json"
bb $kit init >/dev/null
rm $local
git config --unset core.hooksPath
bash .shared/claude/hooks/session-start.sh >/dev/null
[ -f $local ] && [ "$(git config core.hooksPath)" = ".shared/githooks" ] \
  && ok "session start repairs the per-machine items itself" || bad "session start did not repair"

echo "- agent identity: who a Claude session acts as"
AG="$WORK/gh-agent"
mkdir -p "$AG" "$WORK/xdg/gh"
cp kit.edn "$WORK/kit.edn.bak"
bb -e "(spit \"kit.edn\" (pr-str (assoc (clojure.edn/read-string (slurp \"kit.edn\"))
         :agent {:login \"kit-bot\" :email \"kit-bot@example.invalid\" :gh-config-dir \"$AG\"})))"
bb $kit init >/dev/null
printf 'github.com:\n    user: the-owner\n    git_protocol: ssh\n' > "$WORK/xdg/gh/hosts.yml"
as_owner() { env -u GH_CONFIG_DIR XDG_CONFIG_HOME="$WORK/xdg" "$@"; }
expect_exit 0 "outside a Claude session a logged-out agent only warns" as_owner bb $kit doctor
contains "the warning names the agent's config" "WARN  the agent's gh config $AG is not logged in" "$LAST"
contains "the fix is kit init, which logs in" "kit init — it logs kit-bot in" "$LAST"
expect_exit 1 "doctor fails a Claude session that runs gh as the owner" as_owner env CLAUDECODE=1 bb $kit doctor
contains "doctor names the owner's login" "logged in as the-owner" "$LAST"
contains "with settings.local.json in place the fix is a restart" "restart this Claude session: $local is in place" "$LAST"
jq '.env.GH_CONFIG_DIR = "/elsewhere"' $local > "$WORK/local.json" && mv "$WORK/local.json" $local
expect_exit 1 "a session without the agent env fails too" as_owner env CLAUDECODE=1 bb $kit doctor
contains "then the fix is init and a restart" "kit init, then restart this Claude session" "$LAST"
bb $kit init >/dev/null
expect_exit 1 "doctor fails a session whose agent config is logged out" env GH_CONFIG_DIR="$AG" CLAUDECODE=1 bb $kit doctor
contains "inside a session that is a failure" "FAIL  the agent's gh config $AG is not logged in" "$LAST"
printf 'github.com:\n    user: someone-else\n' > "$AG/hosts.yml"
expect_exit 1 "doctor fails when the agent's config holds another login" env GH_CONFIG_DIR="$AG" CLAUDECODE=1 bb $kit doctor
contains "doctor names the wrong login" "logged in as someone-else, not kit-bot" "$LAST"
printf 'github.com:\n    users:\n        kit-bot:\n    git_protocol: https\n    user: kit-bot\n' > "$AG/hosts.yml"
expect_exit 0 "doctor passes a Claude session that acts as the agent" env GH_CONFIG_DIR="$AG" CLAUDECODE=1 bb $kit doctor
expect_exit 1 "doctor fails when GH_TOKEN overrides the agent's config" env GH_CONFIG_DIR="$AG" GH_TOKEN=x CLAUDECODE=1 bb $kit doctor
contains "doctor names the variable" "GH_TOKEN is set" "$LAST"

echo "- agent identity: kit init logs the agent in from a terminal"
if command -v script >/dev/null 2>&1; then
  FB="$WORK/fakebin"
  mkdir -p "$FB"
  cat > "$FB/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh for the login cases: `auth login` stores $FAKE_LOGIN in $GH_CONFIG_DIR/hosts.yml.
echo "gh $*" >> "$GH_CONFIG_DIR/calls"
case "$1 $2" in
  "auth login")  printf 'github.com:\n    user: %s\n' "$FAKE_LOGIN" > "$GH_CONFIG_DIR/hosts.yml" ;;
  "auth logout") rm -f "$GH_CONFIG_DIR/hosts.yml" ;;
esac
FAKE
  chmod +x "$FB/gh"
  tty_run() { script -qec "$(printf '%q ' "$@")" /dev/null; }
  rm -f "$AG/hosts.yml" "$AG/calls"
  expect_exit 0 "init in a terminal logs the agent in" tty_run env PATH="$FB:$PATH" FAKE_LOGIN=kit-bot bb $kit init
  contains "init says which account to sign in as" "check that you are signed in as kit-bot" "$LAST"
  grep -qx "gh auth login --hostname github.com --git-protocol https --web --scopes project,workflow" "$AG/calls" \
    && ok "init runs gh's browser login into the agent's config" || bad "login call" "$(cat "$AG/calls" 2>&1)"
  grep -q "user: kit-bot" "$AG/hosts.yml" && ok "the agent is logged in" || bad "not logged in"
  rm -f "$AG/calls"
  expect_exit 0 "init with the agent logged in" tty_run env PATH="$FB:$PATH" bb $kit init
  [ ! -e "$AG/calls" ] && ok "a logged-in agent is left alone" || bad "logged in again" "$(cat "$AG/calls")"
  printf 'github.com:\n    user: the-owner\n' > "$AG/hosts.yml"
  expect_exit 0 "init with the wrong account in the agent's config" tty_run env PATH="$FB:$PATH" FAKE_LOGIN=the-owner bb $kit init
  grep -qx "gh auth logout --hostname github.com --user the-owner" "$AG/calls" && ok "the wrong account is logged out first" || bad "no logout"
  contains "a browser signed in as someone else is reported" "logged in as the-owner, not kit-bot" "$LAST"
  rm -f "$AG/calls"
  expect_exit 0 "init without a terminal" env PATH="$FB:$PATH" FAKE_LOGIN=kit-bot bb $kit init
  [ ! -e "$AG/calls" ] && ok "without a terminal init starts no login" || bad "login without a terminal"
  contains "and says how to log in" "kit init — it logs kit-bot in" "$LAST"
  rm -f "$AG/calls"
  # Inside a session init fails on the session's identity (gh runs as the owner here); it must not log in.
  expect_exit 1 "init inside a Claude session with a terminal" tty_run env PATH="$FB:$PATH" CLAUDECODE=1 FAKE_LOGIN=kit-bot bb $kit init
  [ ! -e "$AG/calls" ] && ok "a Claude session never starts a login" || bad "login inside a session"
else
  echo "  (skipped: no script command for a pseudo-terminal)"
fi
mv "$WORK/kit.edn.bak" kit.edn
bb $kit init >/dev/null

echo "- agent identity: repositories without dev-kit"
O="$WORK/other"
git init -q "$O"
expect_exit 0 "identity writes the agent env into another repository" bb $kit identity --dir "$O"
[ "$(lenv GIT_AUTHOR_NAME "$O/$local")" = "$default_login" ] && ok "other repository gets the default agent" || bad "other repository env"
git -C "$O" check-ignore -q $local && ok "and ignores the file there" || bad "not ignored in the other repository"
git worktree add -q "$WORK/wt" 2>/dev/null
expect_exit 0 "identity works in a linked worktree" bb $kit identity --dir "$WORK/wt"
git -C "$WORK/wt" check-ignore -q $local && ok "ignored in the worktree" || bad "not ignored in the worktree"
expect_exit 2 "identity refuses a directory that is not a repository root" bb $kit identity --dir "$WORK"

echo "- clojure module"
sed -i 's/:modules  #{}/:modules  #{:clojure}/' kit.edn
expect_exit 0 "modules reports clojure" bb $kit modules
contains "modules output" "clojure=true" "$LAST"
expect_exit 1 "doctor wants the clojure setup" bb $kit doctor --ci
mkdir -p .clj-kondo
printf '{:lint-as {foo/defthing clojure.core/def}\n :linters {:unused-binding {:level :off}}}\n' > .clj-kondo/config.edn
expect_exit 0 "init adds the clojure setup" bb $kit init
[ -L .zprint.edn ] && [ -f .zprint.edn ] && ok ".zprint.edn linked" || bad ".zprint.edn"
bb -e '(let [m (clojure.edn/read-string (slurp ".clj-kondo/config.edn"))] (assert (= ["../.shared/clojure/clj-kondo"] (:config-paths m))) (assert (:lint-as m)))' \
  && ok "clj-kondo config gains config-paths and keeps its own keys" || bad "clj-kondo config" "$(cat .clj-kondo/config.edn)"
[ -f .claude/agents/smell-reviewer.md ] && ok "smell-reviewer added" || bad "smell-reviewer"
jq -e '.permissions.allow | index("Bash(clj-kondo *)")' .claude/settings.json >/dev/null && ok "clojure module allows clj-kondo" || bad "clojure allows"
grep -q "## Clojure design" AGENTS.md && ok "Clojure rules in the block" || bad "clojure rules"

if command -v zprint >/dev/null 2>&1; then
  echo "- pre-commit"
  mkdir -p src
  printf '(ns demo)\n(defn f [x]     (inc x))\n' > src/demo.clj
  git add -A
  expect_exit 1 "pre-commit refuses unformatted Clojure" git commit -qm "feat: demo"
  .shared/clojure/zprint_check.sh --write >/dev/null 2>&1
  git add -A
  expect_exit 0 "pre-commit accepts formatted Clojure" git commit -qm "feat: demo"
else
  echo "- pre-commit: skipped (zprint not installed)"
fi

sed -i 's/:modules  #{:clojure}/:modules  #{}/' kit.edn
expect_exit 0 "init with the module switched off" bb $kit init
[ ! -e .zprint.edn ] && [ ! -e .claude/agents/smell-reviewer.md ] && ok "module files removed as stale" || bad "stale files kept"
contains "init reports removals" "removed, no longer managed" "$LAST"

echo "- SessionStart hook"
out="$(bash .shared/claude/hooks/session-start.sh)"
[ -z "$(grep -v 'local changes' <<<"$out" | grep FAIL)" ] && ok "silent about FAIL when set up" || bad "session-start noisy" "$out"
rm .claude/agents/ops.md
out="$(bash .shared/claude/hooks/session-start.sh)"
contains "reports a broken setup to the agent" ".claude/agents/ops.md: missing" "$out"
bb $kit init >/dev/null
# #3: a newer dev-kit upstream is named at the session's start, with the next step.
UP="$WORK/upstream.git"; git clone -q --bare .shared "$UP"
git clone -q "$UP" "$WORK/up-work" && git -C "$WORK/up-work" commit -q --allow-empty -m "feat: newer dev-kit" \
  && git -C "$WORK/up-work" push -q origin HEAD:refs/heads/main
old_origin="$(git -C .shared remote get-url origin)"; git -C .shared remote set-url origin "$UP"
contains "the session start says dev-kit is behind" "dev-kit is 1 commit behind" "$(bash .shared/claude/hooks/session-start.sh 2>&1)"
contains "  and names the update" "update dev-kit" "$(bash .shared/claude/hooks/session-start.sh 2>&1)"
git -C .shared remote set-url origin "$WORK/no-such-remote"
if bash .shared/claude/hooks/session-start.sh 2>&1 | grep -q behind; then bad "offline: claimed to be behind"; else ok "offline: says nothing about updates"; fi
git -C .shared remote set-url origin "$old_origin"

echo "- delivery guard"
guard() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | bb .shared/claude/hooks/guard.clj; }
contains "denies raw gh issue create" '"permissionDecision":"deny"' "$(guard 'gh issue create --title x')"
contains "denies gh pr create from main" '"permissionDecision":"deny"' "$(guard 'gh pr create --fill')"
[ -z "$(guard 'gh pr create --head 12-landing --fill')" ] && ok "allows gh pr create from an issue branch" || bad "issue branch denied"
[ -z "$(guard 'gh issue create --help')" ] && ok "allows --help" || bad "--help denied"
contains "asks on DELIVERY_GUARD=off" '"permissionDecision":"ask"' "$(guard 'DELIVERY_GUARD=off gh issue create -t x')"
[ -z "$(guard 'git status')" ] && ok "ignores unrelated commands" || bad "unrelated command judged"
# #38: a forced push may rewrite only an issue branch (<number>-<slug>); main is protected on the server too.
FB="$WORK/force"; git init -q -b 42-some-task "$FB"; git init -q -b main "$WORK/force-main"
for c in "git push --force-with-lease origin 42-some-task" "cd $FB && git push --force-with-lease" \
         "git -C $FB push --force-with-lease origin" "git push origin main"; do
  out="$(guard "$c")"
  if [ -z "$out" ]; then ok "push passes: $c"; else bad "push judged: $c" "$out"; fi
done
for c in "git push --force-with-lease origin main" "git push --force-with-lease origin HEAD:main" \
         "cd $WORK/force-main && git push --force-with-lease" "git push --force-if-includes --force-with-lease origin feature-x"; do
  contains "a forced push to a non-issue branch is refused: $c" '"permissionDecision":"deny"' "$(guard "$c")"
done
contains "  the refusal says which branches may be rewritten" "<number>-<slug>" "$(guard 'git push --force-with-lease origin main')"
# #64: in zsh an unquoted $v stays one word, so a command that needs it split is refused.
zguard() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | SHELL=/bin/zsh bb .shared/claude/hooks/guard.clj; }
for c in 'set -- $t' 'env $E bash x.sh' 'for n in $list; do echo $n; done' '$cmd --flag' 'for n in ${list}; do :; done'; do
  contains "zsh: refuses a command relying on splitting: $c" '"permissionDecision":"deny"' "$(zguard "$c")"
done
contains "  the refusal names the fix" '${=' "$(zguard 'set -- $t')"
for c in 'set -- ${=t}' 'for n in ${=list}; do :; done' 'echo "$v"' 'for x in $(seq 3); do :; done' 'env A=1 bash x.sh' 'echo $v'; do
  out="$(zguard "$c")"
  if [ -z "$out" ]; then ok "zsh: passes $c"; else bad "zsh: judged $c" "$out"; fi
done
out="$(jq -nc '{tool_input:{command:"set -- $t"}}' | SHELL=/bin/bash bb .shared/claude/hooks/guard.clj)"
if [ -z "$out" ]; then ok "bash splits words itself: no refusal"; else bad "refused in bash" "$out"; fi
# #54: a gh api call that only reads runs without a window; one that can change GitHub asks the owner.
for c in "gh api repos/u473t8/x" "gh api repos/u473t8/x --paginate --jq '.[] | .name'" \
         "gh api graphql -f query='{viewer{login}}'" "gh api -X GET repos/u473t8/x -f per_page=100"; do
  out="$(guard "$c")"
  if [ -z "$out" ]; then ok "gh api read passes: $c"; else bad "gh api read judged: $c" "$out"; fi
done
for c in "gh api -X POST repos/u473t8/x/issues -f title=t" "gh api repos/u473t8/x/issues -f title=t" \
         "gh api --method=DELETE repos/u473t8/x/git/refs/heads/y" "gh api -XPATCH repos/u473t8/x" \
         "gh api graphql -f query='mutation { addStar(input: {}) { clientMutationId } }'" \
         "gh api graphql -F query=@q.graphql" 'echo "gone: $(gh api -X DELETE repos/u473t8/x/git/refs/heads/y)"'; do
  contains "gh api write asks the owner: $c" '"permissionDecision":"ask"' "$(guard "$c")"
done
if jq -e '.permissions.ask | index("Bash(gh api *)")' .claude/settings.json >/dev/null; then bad "settings still ask for every gh api call"
else ok "settings no longer ask for every gh api call"; fi
# #93: the guard reads commands with a tokenizer, so quoted text is text and nested commands are seen.
for c in 'gh issue create --title "x" --help' 'git commit -m "a && gh issue create -t y"' \
         'gh pr create --head 12-x --title "a; gh issue create"' $'cat <<\'EOF\' > b.md\ngh issue create -t y\nEOF'; do
  out="$(guard "$c")"
  if [ -z "$out" ]; then ok "tokenizer: quoted or heredoc text is no command: $c"; else bad "tokenizer: judged text: $c" "$out"; fi
done
for c in 'bash -c "gh issue create -t x"' "eval 'gh issue create -t x'" 'echo `gh issue create -t x`' \
         $'cat <<<"gh x"\ngh issue create -t y' $'cat <<EOF\nx\nEOF\ngh issue create -t y' 'sh -c "cd /tmp && gh issue create -t x"'; do
  contains "tokenizer: a nested or following command is judged: $c" '"permissionDecision":"deny"' "$(guard "$c")"
done
# The independent review of #93: what a careless reading would let through.
for c in $'cat <<EOF|gh issue create -t y\nbody\nEOF' $'cat <<EOF;gh issue create -t y\nbody\nEOF' \
         $'cat <<A; cat <<B\nx\nA\ny\nB\ngh issue create -t y' $'cat <<EOF\r\nbody\r\nEOF\r\ngh issue create -t y' \
         "echo \$'it\\'s' && gh issue create -t y" "gh issue create --title '--help'" \
         'if true; then gh issue create -t x; fi' 'for x in a b; do gh issue create -t x; done' \
         'sudo -u bob gh issue create -t x' 'sudo -E gh issue create -t x' "bash -lc 'gh issue create -t x'" \
         'echo "$(case x in x) gh issue create -t y;; esac)"' \
         'git -c core.x=y push --force-with-lease origin main' 'git --no-pager push --force-with-lease origin main'; do
  contains "tokenizer: still judged: $c" '"permissionDecision":"deny"' "$(guard "$c")"
done

echo "- fail closed"
jq -e '.hooks.PreToolUse[0].hooks[0].onFailure == "block"' .claude/settings.json >/dev/null && ok "PreToolUse hook fails closed" || bad "PreToolUse onFailure"
[ "$(jq -r .permissions.disableBypassPermissionsMode .claude/settings.json)" = disable ] && ok "bypass mode disabled" || bad "bypass mode"
[ -f .claude/hooks/pretooluse.sh ] && ! grep -q '{{kit}}' .claude/hooks/pretooluse.sh && ok "entry hook in the project, kit path filled in" || bad "entry hook"
entry() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | CLAUDE_PROJECT_DIR="${2:-$P}" bash .claude/hooks/pretooluse.sh; }
contains "entry hook hands calls to the guard" '"permissionDecision":"deny"' "$(entry 'gh issue create --title x')"
mkdir -p "$WORK/nokit"
for c in "git submodule update --init" ".shared/bin/kit init" "git status"; do
  expect_exit 0 "empty kit allows repair: $c" entry "$c" "$WORK/nokit"
done
expect_exit 2 "empty kit refuses other commands" entry "ls -la" "$WORK/nokit"
edit_entry() { jq -nc --arg f "$P/src/x.clj" '{tool_name:"Edit",tool_input:{file_path:$f}}' | CLAUDE_PROJECT_DIR="${1:-$P}" bash .claude/hooks/pretooluse.sh; }
jq -e '.hooks.PreToolUse[0].matcher | test("Edit") and test("Write") and test("Bash")' .claude/settings.json >/dev/null \
  && ok "the entry hook also sees Edit and Write" || bad "the entry hook misses edits"
expect_exit 0 "an edit on a branch without an issue passes the gate" edit_entry
[ -z "$LAST" ] && ok "  with no refusal" || bad "  refused" "$LAST"
expect_exit 2 "an edit with dev-kit missing is refused, with the repair" edit_entry "$WORK/nokit"
contains "refusal names the repair" "git submodule update --init" "$LAST"
nobb="$WORK/nobb"; mkdir -p "$nobb"
for t in bash git awk sed cat head tr grep jq node dirname readlink mktemp rm; do ln -sf "$(command -v $t)" "$nobb/$t"; done
out="$(jq -nc '{tool_input:{command:"gh issue create -t x"}}' | PATH="$nobb" CLAUDE_PROJECT_DIR="$P" bash .claude/hooks/pretooluse.sh 2>&1)"; code=$?
[ "$code" -eq 2 ] && ok "the entry without bb refuses a Bash call (exit 2)" || bad "the entry without bb (exit $code)" "$out"
contains "  and says what to install" "needs Babashka" "$out"
fake="$WORK/fakeclaude"; mkdir -p "$fake"
printf '#!/bin/sh\necho "2.1.200 (Claude Code)"\n' > "$fake/claude"; chmod +x "$fake/claude"
expect_exit 1 "doctor fails on a Claude Code too old for onFailure" env PATH="$fake:$PATH" bb $kit doctor
contains "doctor names the version" "ignores onFailure" "$LAST"
printf '#!/bin/sh\necho "2.1.322 (Claude Code)"\n' > "$fake/claude"
out="$(PATH="$fake:$PATH" bb $kit doctor 2>&1)"
grep -q "ignores onFailure" <<<"$out" && bad "new enough Claude Code flagged" "$out" || ok "new enough Claude Code passes"

echo "- safety guard: destructive commands and secret reads (#20)"
export CC_SAFETY_NET_HOME="$WORK/ccsn"
call() { # call <tool> <tool_input JSON>: the project's PreToolUse entry hook, as Claude Code calls it
  jq -nc --arg t "$1" --argjson i "$2" --arg d "$P" '{tool_name:$t, tool_input:$i, hook_event_name:"PreToolUse", cwd:$d}' \
    | CLAUDE_PROJECT_DIR="$P" bash .claude/hooks/pretooluse.sh 2>&1; }
refused() { grep -q '"permissionDecision":"deny"' <<<"$2" && ok "$1" || bad "$1" "$2"; }
passes() { grep -q '"permissionDecision":"deny"' <<<"$2" && bad "$1" "$2" || ok "$1"; }
jq -e '.hooks.PreToolUse[0].matcher | test("Read") and test("Grep") and test("Glob")' .claude/settings.json >/dev/null \
  && ok "the entry hook sees reads too" || bad "the entry hook misses reads"
refused "refuses: git reset --hard" "$(call Bash '{"command":"git reset --hard"}')"
contains "  naming the rule" "Rule: git.reset-hard" "$(call Bash '{"command":"git reset --hard"}')"
refused "refuses: git push -uf origin x (combined flags)" "$(call Bash '{"command":"git push -uf origin x"}')"
refused "refuses: bash -c 'git reset --hard'" "$(call Bash "$(jq -nc '{command: "bash -c '"'"'git reset --hard'"'"'"}')")"
refused "refuses: cat .env" "$(call Bash '{"command":"cat .env"}')"
refused "refuses: a Read of .env" "$(call Read '{"file_path":".env"}')"
refused "refuses: a Grep in .env" "$(call Grep '{"pattern":"K","path":".env"}')"
passes "lets through: --force-with-lease to an issue branch (#38)" "$(call Bash '{"command":"git push --force-with-lease origin 5-x"}')"
passes "lets through: git status" "$(call Bash '{"command":"git status"}')"
passes "lets through: a Read of README.md" "$(call Read '{"file_path":"README.md"}')"
refused "the delivery guard still runs after it" "$(call Bash '{"command":"gh issue create --title x"}')"
[ -f .cc-safety-net/policy.json ] && ok "init writes the project's policy" || bad "no .cc-safety-net/policy.json"
cp .cc-safety-net/policy.json "$WORK/policy.json"; echo hi > notes.txt
jq '.secret_protection = {deny_paths: ["notes.txt"]}' "$WORK/policy.json" > .cc-safety-net/policy.json
refused "the guard reads the project's .cc-safety-net/policy.json" "$(call Bash '{"command":"cat notes.txt"}')"
cp "$WORK/policy.json" .cc-safety-net/policy.json; rm -f notes.txt
passes "  and the default policy lets that file through" "$(call Bash '{"command":"cat notes.txt"}')"
oldnode="$WORK/oldnode"; mkdir -p "$oldnode"; printf '#!/bin/sh\necho v18.19.0\n' > "$oldnode/node"; chmod +x "$oldnode/node"
out="$(PATH="$oldnode:$PATH" call Bash '{"command":"git status"}')"; code=$?
[ "$code" -eq 2 ] && ok "with Node older than 22 every guarded call is refused (exit 2)" || bad "old Node (exit $code)" "$out"
contains "  saying what to install" "Node 22 or later" "$out"
noisy="$WORK/noisynode"; mkdir -p "$noisy"; printf '#!/bin/sh\necho "(node) a warning" >&2\nexec %s "$@"\n' "$(command -v node)" > "$noisy/node"; chmod +x "$noisy/node"
out="$(PATH="$noisy:$PATH" call Bash '{"command":"git status"}' 2>/dev/null)"; code=$?
[ "$code" -eq 0 ] && [ -z "$out" ] && ok "a warning from Node on stderr does not reach the hook's answer" || bad "noisy Node (exit $code)" "$out"
expect_exit 1 "doctor names a Node older than 22" env PATH="$oldnode:$PATH" bb $kit doctor
contains "  with the fix" "nvm install 22" "$LAST"
V="$KIT/vendor/cc-safety-net"; version="$(sed -n 's/^version=//p' "$V/PIN")"; integrity="$(sed -n 's/^integrity=//p' "$V/PIN")"
if curl -fsSL -o "$WORK/ccsn.tgz" "https://registry.npmjs.org/cc-safety-net/-/cc-safety-net-$version.tgz" 2>/dev/null; then
  [ "sha512-$(openssl dgst -sha512 -binary "$WORK/ccsn.tgz" | openssl base64 -A)" = "$integrity" ] \
    && ok "the npm release $version has the pinned sha512" || bad "the release's sha512 differs from PIN"
  mkdir -p "$WORK/ccsn-pkg" && tar -xzf "$WORK/ccsn.tgz" -C "$WORK/ccsn-pkg"
  differ="$(cd "$V" && find . -type f ! -name PIN ! -name README.md | while read -r f; do cmp -s "$f" "$WORK/ccsn-pkg/package/$f" || echo "$f"; done)"
  [ -z "$differ" ] && ok "the vendored files are the release's, byte for byte" || bad "vendored files differ from the release" "$differ"
elif [ -n "${CI:-}" ]; then
  bad "the npm release cc-safety-net $version could not be downloaded, so the vendored copy is unchecked"
else
  echo "  skip  vendored copy against the npm release (offline)"
fi

echo "- flow scripts, offline guards"
export GHWF_OWNER=u473t8 GHWF_PROJECT_NUMBER=3 GHWF_REPO=u473t8/kit-selftest
expect_exit 1 "start refuses an issue without priority" bb .shared/bin/kit start --title x
contains "start names the scale" "Urgent|High|Medium|Low" "$LAST"
expect_exit 1 "start refuses an off-scale priority" bb .shared/bin/kit start --title x --priority Critical
expect_exit 1 "finish refuses a non-conventional type" bb .shared/bin/kit finish --type update
expect_exit 1 "finish has no merge mode" bb .shared/bin/kit finish --merge
contains "finish rejects --merge" "Unknown argument: --merge" "$LAST"
expect_exit 1 "merge refuses to run on main" bb .shared/bin/kit merge
contains "merge explains" "Run from the issue branch" "$LAST"
expect_exit 0 "merge has help" bb .shared/bin/kit merge --help
expect_exit 0 "start: --help before an unknown option shows the help" bb .shared/bin/kit start --help --bogus
contains "  the usage" "Usage: kit start" "$LAST"
expect_exit 1 "finish refuses to run on main" bb .shared/bin/kit finish
contains "finish explains" "On the base branch" "$LAST"

echo "- finish and merge scripts (fake gh)"
FAKE="$WORK/fake"; mkdir -p "$FAKE"
export FAKE_GH_DIR="$FAKE" FAKE_GH_LOG="$FAKE/log"
REMOTE="$WORK/remote.git"; git init -q --bare -b main "$REMOTE"
T="$WORK/flow"; git init -q -b main "$T"; cd "$T" || exit 1
git remote add origin "$REMOTE"; echo base > f; git add f; git commit -qm "chore: base"; git push -q -u origin main
git switch -q -c 12-landing
flow() { local cmd="$1"; shift; PATH="$KIT/test/fake-gh:$PATH" GHWF_REPO=u473t8/fake GHWF_OWNER=u473t8 GHWF_PROJECT_NUMBER=3 bb "$KIT/bin/kit" "$cmd" "$@"; }
head_now() { git rev-parse HEAD; }

: > "$FAKE/pr-list"; echo "Add Landing page" > "$FAKE/issue-title"
echo change >> f; git add f; before=$(head_now)
expect_exit 1 "finish: missing body file stops before the commit" flow finish --pr-body-file "$WORK/none.md"
[ "$(head_now)" = "$before" ] && ok "  nothing committed" || bad "  committed anyway"
printf 'text\nADR: \n' > "$WORK/empty-adr.md"
expect_exit 1 "finish: empty ADR line stops before the commit" flow finish --pr-body-file "$WORK/empty-adr.md"
[ "$(head_now)" = "$before" ] && ok "  nothing committed" || bad "  committed anyway"
expect_exit 1 "finish: no open PR and no body file stops before the commit" flow finish
printf 'did it\n' > "$WORK/bad-msg.txt"
expect_exit 1 "finish: commit message without type(GH-n) refused" flow finish --commit-message-file "$WORK/bad-msg.txt" --pr-body-file "$WORK/empty-adr.md"

git switch -q -c hotfix; expect_exit 1 "finish: a branch without an issue number stops before the commit" flow finish --pr-body-file "$WORK/empty-adr.md"
contains "  names the way out" "kit start" "$LAST"
git switch -q 12-landing; git branch -q -D hotfix
printf '## Review\n<!-- hint -->\n\n## User-level test\nRan it.\n\nADR: none\n' > "$WORK/no-review.md"
expect_exit 1 "finish: a Review section with only the hint stops before the commit (#21)" flow finish --pr-body-file "$WORK/no-review.md"
contains "  with the same words as CI" "fill in ## Review" "$LAST"
grep -q '^  FAIL' <<<"$LAST" && ok "  the gate's lines keep their indent" || bad "  the gate's lines" "$LAST"
[ "$(head_now)" = "$before" ] && ok "  nothing committed" || bad "  committed anyway"
printf '## What changed\n- x\n\n## Review\nLooked at it.\n\n## User-level test\nRan it.\n\nADR: none\n' > "$WORK/body.md"
expect_exit 1 "finish: a type outside Conventional Commits stops before the commit" flow finish --type update --pr-body-file "$WORK/body.md"
contains "  names the way out" "pass --type" "$LAST"
[ "$(head_now)" = "$before" ] && ok "  nothing committed" || bad "  committed anyway"
: > "$FAKE_GH_LOG"
expect_exit 0 "finish: a closed PR does not count; a new one is opened" flow finish --pr-body-file "$WORK/body.md"
grep -q '^pr create' "$FAKE_GH_LOG" && ok "  gh pr create called" || bad "  no pr create" "$(cat "$FAKE_GH_LOG")"
cmp -s "$FAKE/pr-body" <(printf 'Closes #12\n\n%s' "$(cat "$WORK/body.md")") \
  && ok "  the body as written, no trailing newline" || bad "  the body" "$(od -c "$FAKE/pr-body" | tail -3)"
contains "  gh's own lines reach the terminal" "Creating pull request" "$LAST"
grep -q 'pr list .*--state open' "$FAKE_GH_LOG" && ok "  only open PRs looked up" || bad "  lookup not limited to open PRs"
grep -q '^pr merge https://github.com/u473t8/fake/pull/99 --auto --squash' "$FAKE_GH_LOG" \
  && ok "  auto-merge turned on: the owner's Approve merges it" || bad "  auto-merge not turned on" "$(cat "$FAKE_GH_LOG")"
contains "  subject from the issue title, first letter lowered" "Subject: feat(GH-12): add Landing page" "$LAST"
[ "$(git log -1 --format=%s)" = "feat(GH-12): add Landing page" ] && ok "  commit carries the subject" || bad "  commit subject"
[ "$(git rev-parse origin/12-landing 2>/dev/null)" = "$(head_now)" ] && ok "  branch pushed" || bad "  branch not pushed"

echo "https://github.com/u473t8/fake/pull/99" > "$FAKE/pr-list"; : > "$FAKE_GH_LOG"
echo more >> f; git add f
printf 'fix(GH-12): handle more\n\nbody\n' > "$WORK/msg.txt"
expect_exit 0 "finish: an open PR needs no body file" flow finish --type fix --commit-message-file "$WORK/msg.txt"
grep -q '^pr create' "$FAKE_GH_LOG" && bad "  opened a second PR" || ok "  no second PR"
contains "  subject from the commit message file" "Subject: fix(GH-12): handle more" "$LAST"

: > "$FAKE/pr-list"; : > "$FAKE_GH_LOG"; echo more >> f; git add f
printf 'fix(GH-12): handle even more\n' > "$WORK/msg2.txt"
flow_rh() { GHWF_REVIEWERS=shundeev/owners GHWF_HUMAN=the-human flow "$@"; }
flow_r() { GHWF_REVIEWERS=shundeev/owners flow "$@"; }
expect_exit 0 "finish: a new PR with reviewers and the person behind the agent" \
  flow_rh finish --commit-message-file "$WORK/msg2.txt" --pr-body-file "$WORK/body.md"
grep -qx 'pr edit https://github.com/u473t8/fake/pull/99 --add-reviewer shundeev/owners --add-assignee the-human' "$FAKE_GH_LOG" \
  && ok "  asks the owners for a review and assigns the person" || bad "  no review request or assignee" "$(grep '^pr edit' "$FAKE_GH_LOG")"
: > "$FAKE_GH_LOG"; echo again >> f; git add f
printf 'fix(GH-12): handle once more\n' > "$WORK/msg3.txt"
expect_exit 0 "finish: without GHWF_HUMAN" flow_r finish --commit-message-file "$WORK/msg3.txt" --pr-body-file "$WORK/body.md"
contains "  warns and names the fix" "kit init" "$LAST"
echo "https://github.com/u473t8/fake/pull/99" > "$FAKE/pr-list"

git switch -q -c 13-typo main
echo typo >> f; git commit -qam "fix(GH-13): correct the typo"
: > "$FAKE/pr-list"; : > "$FAKE_GH_LOG"
expect_exit 0 "finish --no-commit without --type" flow finish --no-commit --summary "correct a typo" --pr-body-file "$WORK/body.md"
contains "  the PR type comes from the branch's first commit" "Subject: fix(GH-13): correct a typo" "$LAST"
expect_exit 0 "finish --no-commit with --type" flow finish --no-commit --type docs --summary "correct a typo" --pr-body-file "$WORK/body.md"
contains "  an explicit --type wins" "Subject: docs(GH-13): correct a typo" "$LAST"
: > "$FAKE_GH_LOG"
expect_exit 0 "finish: --owner \"\" leaves the board alone" flow finish --no-commit --summary "x" --owner "" --pr-body-file "$WORK/body.md"
grep -q '^project' "$FAKE_GH_LOG" && bad "  the board was touched" "$(grep '^project' "$FAKE_GH_LOG")" || ok "  no board call"
git remote set-url origin "$WORK/nowhere.git"
expect_exit 128 "finish: a failed push ends with git's exit code" flow finish --no-commit --summary "x" --pr-body-file "$WORK/body.md"
git remote set-url origin "$REMOTE"
git switch -q 12-landing
echo "https://github.com/u473t8/fake/pull/99" > "$FAKE/pr-list"

export GHWF_MERGE_WAIT=0
echo "REVIEW_REQUIRED BLOCKED" > "$FAKE/pr-review"; echo OPEN > "$FAKE/pr-state"; : > "$FAKE_GH_LOG"
expect_exit 1 "merge: refuses without the owner's Approve" flow merge
contains "  says what it waits for" "Waiting for the owner's Approve" "$LAST"
if grep -q '^pr merge' "$FAKE_GH_LOG"; then bad "  tried to merge"; else ok "  no merge attempted"; fi
echo "APPROVED CLEAN" > "$FAKE/pr-review"
touch "$FAKE/no-auto-merge"; : > "$FAKE_GH_LOG"
expect_exit 1 "merge: without auto-merge in the repository" flow merge
calls="$(grep -E '^pr merge' "$FAKE_GH_LOG" | sed 's/ https:[^ ]*//' | tr '\n' ',')"
[ "$calls" = "pr merge --auto --squash,pr merge --squash," ] && ok "  falls back to a plain squash merge" || bad "  no fallback" "$calls"
rm "$FAKE/no-auto-merge"
expect_exit 1 "merge: a PR that did not merge keeps its branch" flow merge
contains "  says it is not merged yet" "not merged yet" "$LAST"
GHWF_MERGE_WAIT=abc expect_exit 1 "merge: a GHWF_MERGE_WAIT that is no number is named" flow merge
contains "  with the fix" "GHWF_MERGE_WAIT is 'abc'" "$LAST"
git rev-parse -q --verify refs/heads/12-landing >/dev/null && ok "  branch kept" || bad "  branch deleted"

W="$WORK/main-wt"; git worktree add -q "$W" main
echo "APPROVED BEHIND" > "$FAKE/pr-review"; echo MERGED > "$FAKE/pr-state"; : > "$FAKE_GH_LOG"
expect_exit 0 "merge: works while main is checked out in another worktree" flow merge
calls="$(grep -E '^pr (update-branch|merge)' "$FAKE_GH_LOG" | cut -d' ' -f1,2 | tr '\n' ',')"
[ "$calls" = "pr update-branch,pr merge," ] && ok "  a branch behind main is updated, then merged" || bad "  update and merge order" "$calls"
git rev-parse -q --verify refs/heads/12-landing >/dev/null && bad "  local branch left" || ok "  local branch deleted"
git ls-remote --exit-code --heads origin 12-landing >/dev/null 2>&1 && bad "  remote branch left" || ok "  remote branch deleted"
[ "$(git rev-parse --abbrev-ref HEAD)" = HEAD ] && ok "  this worktree detached on the base" || bad "  not detached"

# #72: a branch that falls behind while the script waits is updated, then merges.
git switch -q -c 15-wait origin/main && git push -q -u origin 15-wait
echo "https://github.com/u473t8/fake/pull/97" > "$FAKE/pr-list"; echo "APPROVED CLEAN" > "$FAKE/pr-review"
printf 'OPEN BLOCKED\nOPEN BEHIND\nOPEN BLOCKED\nMERGED CLEAN\n' > "$FAKE/pr-state.seq"; : > "$FAKE_GH_LOG"
export GHWF_MERGE_POLL=0 GHWF_MERGE_WAIT=10
expect_exit 0 "merge: a branch that falls behind while waiting is updated and merges" flow merge
unset GHWF_MERGE_POLL; export GHWF_MERGE_WAIT=0  # as the tests around it expect
calls="$(grep -E '^pr (update-branch|merge)' "$FAKE_GH_LOG" | cut -d' ' -f1,2 | tr '\n' ',')"
[ "$calls" = "pr merge,pr update-branch," ] && ok "  auto-merge, then an update when it fell behind" || bad "  calls" "$calls"
rm -f "$FAKE/pr-state.seq"; : > "$FAKE/pr-list"; git switch -q --detach origin/main

git switch -q -c 14-auto origin/main && git push -q -u origin 14-auto
: > "$FAKE/pr-list"; echo "https://github.com/u473t8/fake/pull/98" > "$FAKE/pr-list-merged"; : > "$FAKE_GH_LOG"
expect_exit 0 "merge: a PR already merged by GitHub gets the closeout only" flow merge
if grep -q '^pr merge' "$FAKE_GH_LOG"; then bad "  merged again"; else ok "  no second merge"; fi
grep -q '^project item-add' "$FAKE_GH_LOG" && ok "  the card is moved to Done" || bad "  no board update"
git rev-parse -q --verify refs/heads/14-auto >/dev/null && bad "  local branch left" || ok "  local branch deleted"

# #97: the edge cases the retrospectives met.
git switch -q -c 41-merged origin/main && git push -q -u origin 41-merged
echo "https://github.com/u473t8/fake/pull/90" > "$FAKE/pr-list"; : > "$FAKE/pr-list-merged"
echo "APPROVED CLEAN" > "$FAKE/pr-review"; echo MERGED > "$FAKE/pr-state"; touch "$FAKE/no-auto-merge"; : > "$FAKE_GH_LOG"
expect_exit 0 "merge: a PR GitHub merged while auto-merge was refused goes to the closeout (site#18)" flow merge
grep -q "Auto-merge not available" <<<"$LAST" && bad "  warned that auto-merge is not available" || ok "  no 'Auto-merge not available' line"
grep -q '^pr merge [^ ]* --squash$' "$FAKE_GH_LOG" && bad "  tried a plain merge" || ok "  no second merge"
rm "$FAKE/no-auto-merge"
git switch -q -c 42-dirty origin/main && git push -q -u origin 42-dirty
echo "APPROVED DIRTY" > "$FAKE/pr-review"; echo OPEN > "$FAKE/pr-state"; : > "$FAKE_GH_LOG"
expect_exit 1 "merge: a conflict with the base stops at once (#27)" flow merge
contains "  says to merge the base in" "merge origin/main" "$LAST"; contains "  and that the push dismisses the approval" "dismisses" "$LAST"
grep -q '^pr merge' "$FAKE_GH_LOG" && bad "  tried to merge" || ok "  no merge attempted"
git rev-parse -q --verify refs/heads/42-dirty >/dev/null && ok "  branch kept" || bad "  branch deleted"

git switch -q -c 43-silent origin/main
echo "https://github.com/u473t8/fake/pull/91" > "$FAKE/pr-list"

# A gh call that fails with no message names itself and its exit code (#95).
touch "$FAKE/silent-fail"
expect_exit 3 "finish: a silent gh failure keeps gh's exit code" flow finish --no-commit --summary x --pr-body-file "$WORK/body.md"
contains "  names the command" "gh pr list" "$LAST"; contains "  and the exit code" "exit code 3" "$LAST"
rm "$FAKE/silent-fail"; git switch -q --detach origin/main
unset GHWF_MERGE_WAIT

echo "- start script and board updates (#12, #41, fake gh)"
B="$WORK/board"; mkdir -p "$B"
export FAKE_GH_DIR="$B" FAKE_GH_LOG="$B/log" GHWF_MERGE_WAIT=0
echo '{"data":{"search":{"nodes":[]}}}' > "$B/missing.json"
# node <title> <type Issue|DraftIssue> <number> <state OPEN|CLOSED|""> <status>: one board item as the start script's query returns it
node() { jq -nc --arg t "$1" --arg ty "$2" --arg n "$3" --arg st "$4" --arg s "$5" \
  '{id: ("PVTI_" + $t), isArchived: false, status: (if $s == "" then null else {name: $s} end),
    content: ({__typename: $ty, title: $t} + (if $ty == "Issue" then {number: ($n|tonumber), url: ("https://github.com/u473t8/fake/issues/" + $n), state: $st} else {} end))}'; }
board() { printf '%s\n' "$@" | jq -cs '{data: {owner: {projectV2: {items: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}}' > "$B/project-items.json"; }
start() { : > "$FAKE_GH_LOG"; PATH="$KIT/test/fake-gh:$PATH" GHWF_REPO=u473t8/fake GHWF_OWNER=u473t8 GHWF_PROJECT_NUMBER=3 \
  bb "$KIT/bin/kit" start --priority High --no-checkout "$@"; }

board "$(node Recurring Issue 5 CLOSED Done)" "$(node Recurring Issue 6 OPEN Done)"
expect_exit 0 "start: a title of closed or Done work files a new issue" start --title Recurring
contains "  the new one" "Issue Number: 77" "$LAST"
grep -q -- 'issue list .*--state open' "$FAKE_GH_LOG" && ok "  title search looks at open issues only" || bad "  issue search" "$(grep 'issue list' "$FAKE_GH_LOG")"
board "$(node Recurring Issue 8 OPEN 'In progress')"
expect_exit 0 "start: open work with the title is reused" start --title Recurring
contains "  that issue" "Issue Number: 8" "$LAST"
board "$(node 'Draft task' DraftIssue 0 '' Backlog)"
echo '{"data":{"convertProjectV2DraftIssueItemToIssue":{"item":{"content":{"number":78,"url":"https://github.com/u473t8/fake/issues/78"}}}}}' > "$B/convert.json"
expect_exit 0 "start: a same-title draft is converted" start --title "Draft task"
contains "  into an issue" "Issue Number: 78" "$LAST"
grep -q 'itemId=PVTI_Draft task' "$FAKE_GH_LOG" && ok "  through itemId, as the schema has it" || bad "  mutation input" "$(grep convert "$FAKE_GH_LOG")"
board "$(node Recurring Issue 8 OPEN 'In progress')"
expect_exit 0 "start: --issue wins over a same-title item" start --title Recurring --issue 9
contains "  issue 9" "Issue Number: 9" "$LAST"
expect_exit 0 "start: --issue with --no-reuse-existing files nothing new" start --title Recurring --issue 9 --no-reuse-existing
grep -q '^issue create' "$FAKE_GH_LOG" && bad "  filed a duplicate" || ok "  no duplicate"
touch "$B/issue-missing"; expect_exit 1 "start: --issue of no issue is refused" start --title x --issue 404
contains "  naming the number" "#404" "$LAST"; rm "$B/issue-missing"
board
expect_exit 0 "start: without a body the issue is still filed" start --title "No body"
grep -q '^issue create .*--body' "$FAKE_GH_LOG" && ok "  gh gets an empty --body" || bad "  no --body" "$(grep 'issue create' "$FAKE_GH_LOG")"
expect_exit 0 "start: a missing label is created" start --title "Labelled" --labels fresh-label
grep -q '^label create fresh-label' "$FAKE_GH_LOG" && grep -q 'issue create .*--label fresh-label' "$FAKE_GH_LOG" \
  && ok "  and put on the issue" || bad "  labels" "$(grep -E 'label|issue create' "$FAKE_GH_LOG")"
[ "$(grep -c '^label create fresh-label' "$FAKE_GH_LOG")" -eq 1 ] && ok "  created once" \
  || bad "  created $(grep -c '^label create fresh-label' "$FAKE_GH_LOG") times"
printf 'Drafted body\n\n' > "$WORK/draft-body.md"
expect_exit 0 "start: a draft gets its body file" start --title "Drafted" --mode draft-convert --body-file "$WORK/draft-body.md"
cmp -s "$B/draft-body" <(printf 'Drafted body') && ok "  without its trailing newlines" || bad "  the body" "$(od -c "$B/draft-body")"
expect_exit 0 "start: a draft with an empty --body" start --title "Bare draft" --mode draft-convert --body ""
grep '^project item-create' "$FAKE_GH_LOG" | grep -q -- '--body' && bad "  gets --body" "$(grep '^project item-create' "$FAKE_GH_LOG")" || ok "  gets none"
bignodes=(); for i in $(seq 1 1500); do bignodes+=("$(node "Old task number $i with a title long enough to fill the board quickly" Issue $((1000+i)) OPEN Done)"); done
board "${bignodes[@]}"
expect_exit 0 "start: a board of 1500 items is read" start --title "On a big board"
grep -q "Argument list too long" <<<"$LAST" && bad "  argument limit" || ok "  with no argument limit"
board
echo 'GraphQL: Your token has not been granted the required scopes to execute this query. (INSUFFICIENT_SCOPES)' > "$B/board-fails"
expect_exit 1 "start: a failed board update stops it (#41)" start --title "Scoped" --showcase Site
contains "  names the issue" "#77" "$LAST"; contains "  the field and value" "Showcase" "$LAST"
contains "  GitHub's reason" "INSUFFICIENT_SCOPES" "$LAST"; contains "  and the fix" "gh auth refresh" "$LAST"
echo 'GraphQL: Could not resolve to a ProjectV2 with the number 3. (NOT_FOUND)' > "$B/board-fails"
expect_exit 1 "start: no access to the board" start --title "No board"
contains "  says so" "no access to the board" "$LAST"
rm -f "$B/board-fails"; start --title "Steady" >/dev/null 2>&1; edits="$(grep -c '^project item-edit' "$FAKE_GH_LOG")"
printf 'HTTP 502: Bad Gateway\nok\n' > "$B/board-fails.seq"
expect_exit 0 "start: a passing GitHub error is retried once" start --title "Flaky"
[ "$(grep -c '^project item-edit' "$FAKE_GH_LOG")" -eq $((edits + 1)) ] && ok "  one call more, and it goes on" \
  || bad "  edits" "$(grep -c '^project item-edit' "$FAKE_GH_LOG") against $edits"
rm -f "$B/board-fails.seq"
opt() { grep '^project item-edit' "$FAKE_GH_LOG" | grep -o 'option-id o[0-9]' | head -1; }
start --title "Fresh" >/dev/null 2>&1; [ "$(opt)" = "option-id o1" ] && ok "start: a new issue starts in Backlog" || bad "  default status" "$(opt)"
start --title "Known" --issue 9 >/dev/null 2>&1; [ "$(opt)" = "option-id o2" ] && ok "start: --issue sets In progress (#27)" || bad "  status of --issue" "$(opt)"
start --title "Known" --issue 9 --status Done >/dev/null 2>&1; [ "$(opt)" = "option-id o4" ] && ok "start: --status wins over --issue" || bad "  --status" "$(opt)"
expect_exit 1 "start: an option the board lacks names the ones it has" start --title "Odd size" --size XXL
contains "  the options" "its options: S, M" "$LAST"

cd "$T" || exit 1; git switch -q -c 31-board origin/main; echo b >> f; git add f
echo 'GraphQL: Your token has not been granted the required scopes to execute this query. (INSUFFICIENT_SCOPES)' > "$B/board-fails"
: > "$B/pr-list"; echo "Board task" > "$B/issue-title"
expect_exit 1 "finish: a failed In review update stops it, after the PR is open" flow finish --pr-body-file "$WORK/body.md"
contains "  says the PR is open" "is open" "$LAST"; contains "  with the command for the status alone" "kit board set" "$LAST"
rm -f "$B/board-fails"; cmd="${LAST##*Set it alone: }"
expect_exit 0 "  and that command, run as printed, sets it" env PATH="$KIT/test/fake-gh:$PATH" bash -c "$cmd"
contains "  to In review" "Status: In review" "$LAST"
echo 'GraphQL: Your token has not been granted the required scopes to execute this query. (INSUFFICIENT_SCOPES)' > "$B/board-fails"
git switch -q --detach origin/main
git switch -q -c 32-board origin/main && git push -q -u origin 32-board
: > "$B/pr-list"; echo "https://github.com/u473t8/fake/pull/98" > "$B/pr-list-merged"; echo "MERGED CLEAN" > "$B/pr-state"
expect_exit 1 "merge: a failed Done update stops it, after the merge" flow merge
contains "  with the command for the status alone" "kit board set" "$LAST"
rm -f "$B/board-fails" "$B/pr-list-merged"; git switch -q --detach origin/main
export FAKE_GH_DIR="$FAKE" FAKE_GH_LOG="$FAKE/log"
echo "- the repository of the folder, not the session's (#81)"
# A session opened in one project (GHWF_REPO=u473t8/fake, set by flow) works in another repository's
# folder: its origin is on GitHub, pushes go to the local remote.
FR="$WORK/folder"; git init -q -b 7-x "$FR"; cd "$FR" || exit 1
git remote add origin git@github.com:u473t8/folder.git; git remote set-url --push origin "$REMOTE"
echo x > g; git add g; git commit -qm "chore: base"
repo_calls() { grep -oE 'u473t8/(fake|folder)' "$FAKE_GH_LOG" | sort -u | tr '\n' ' '; }
: > "$FAKE/pr-list"; : > "$FAKE/pr-list-merged"; : > "$FAKE_GH_LOG"
expect_exit 1 "merge: no pull request is looked for in the folder's repository" flow merge
contains "  the error names the repository" "u473t8/folder" "$LAST"
contains "  and the option that changes it" "--repo" "$LAST"
[ "$(repo_calls)" = "u473t8/folder " ] && ok "  every call names the folder's repository" || bad "  repositories" "$(repo_calls)"
: > "$FAKE_GH_LOG"; flow start --title "Folder task" --issue 7 --priority Low --no-checkout >/dev/null 2>&1
[ "$(repo_calls)" = "u473t8/folder " ] && ok "start: acts on the folder's repository" || bad "start: repositories" "$(repo_calls)"
echo y >> g; git add g; : > "$FAKE_GH_LOG"; echo "Folder task" > "$FAKE/issue-title"
flow finish --pr-body-file "$WORK/body.md" >/dev/null 2>&1
grep -qE '^pr create .*u473t8/folder' "$FAKE_GH_LOG" && ok "finish: opens the PR in the folder's repository" \
  || bad "finish: repositories" "$(repo_calls)"
kitf() { env -u GITHUB_REPOSITORY PATH="$KIT/test/fake-gh:$PATH" GHWF_REPO=u473t8/fake bb "$KIT/bin/kit" "$@"; }  # CI sets GITHUB_REPOSITORY
: > "$FAKE_GH_LOG"; kitf retro --missing >/dev/null 2>&1
[ "$(repo_calls)" = "u473t8/folder " ] && ok "kit retro: asks about the folder's repository" || bad "kit retro: repositories" "$(repo_calls)"
: > "$FAKE_GH_LOG"; kitf gate --g1 7 >/dev/null 2>&1
grep -q 'n=folder' "$FAKE_GH_LOG" && ! grep -q 'n=fake' "$FAKE_GH_LOG" && ok "kit gate: reads the folder's issue" \
  || bad "kit gate: queries" "$(cat "$FAKE_GH_LOG")"
NR="$WORK/no-remote"; git init -q -b 8-y "$NR"; cd "$NR" || exit 1
expect_exit 1 "merge: no origin and no GHWF_REPO is refused" env -u GHWF_REPO PATH="$KIT/test/fake-gh:$PATH" bb "$KIT/bin/kit" merge
contains "  with the way out" "pass --repo owner/name" "$LAST"
cd "$P" || exit 1

echo "- design approval gate (fake gh)"
G="$WORK/gate"; mkdir -p "$G"
gate() { PATH="$KIT/test/fake-gh:$PATH" FAKE_GH_DIR="$G" FAKE_GH_LOG="$G/log" GITHUB_REPOSITORY=u473t8/fake bb "$KIT/bin/kit" gate "$@"; }
# issue <labels as JSON> <labeled by> <labeled at> <body edited at|null> <design comment created> <design comment edited|null>
issue() {
  jq -n --argjson labels "$1" --arg by "$2" --arg at "$3" --arg edited "$4" --arg dc "$5" --arg de "$6" \
    '{data: {repository: {issue: {
       state: "OPEN",
       lastEditedAt: (if $edited == "null" then null else $edited end),
       labels: {nodes: ($labels | map({name: .}))},
       timelineItems: {nodes: [{actor: {login: $by}, label: {name: "design-approved"}, createdAt: $at}]},
       comments: {nodes: [{author: {login: "someone"}, createdAt: $dc, body: "## Design (proposed)",
                           lastEditedAt: (if $de == "null" then null else $de end)}]}}}}}' > "$G/gate-issue.json"
}
# pr-files.json holds what `gh api --paginate …/files --jq '.[]'` prints: one file per line.
files() { jq -nc --argjson n "$1" '{filename: "src/a.clj", status: "modified", additions: $n, deletions: 0},
                                   {filename: "package-lock.json", status: "modified", additions: 900, deletions: 0}' > "$G/pr-files.json"; }
GOOD_BODY=$'## What changed\n- x\n\n## Review\n<!-- hint -->\nSelf-review: fine.\n\n## User-level test\nRan it.\n\nADR: none'
# pr <title> [body]: what `gh api …/pulls/<n>` prints after the gate's filter
pr() { jq -nc --arg t "$1" --arg b "${2-$GOOD_BODY}" '{title: $t, body: $b}' > "$G/pr.json"; }
echo admin > "$G/perm-the-owner"; echo write > "$G/perm-$default_login"; files 50; pr "feat(GH-26): add x"
T0=2026-11-12T10:00:00Z; T1=2026-11-12T11:00:00Z; T2=2026-11-12T12:00:00Z
issue '["design-approved","size:M"]' the-owner $T1 null $T0 null
expect_exit 0 "gate: an approved M issue passes" gate --branch 26-x --pr 7
contains "  names who approved" "approved by the-owner" "$LAST"
issue '["size:M"]' the-owner $T1 null $T0 null
expect_exit 1 "gate: an M issue without design-approved fails" gate --branch 26-x --pr 7
contains "  says what to do" "design-approved" "$LAST"
issue '["design-approved","size:M"]' "$default_login" $T1 null $T0 null
expect_exit 1 "gate: a label set by the agent does not count" gate --branch 26-x --pr 7
contains "  names the agent" "set by the agent" "$LAST"
issue '["design-approved","size:M"]' the-owner $T1 $T2 $T0 null
expect_exit 1 "gate: the issue body edited after the approval fails" gate --branch 26-x --pr 7
contains "  says the approval is stale" "after the approval" "$LAST"
issue '["design-approved","size:M"]' the-owner $T1 null $T0 $T2
expect_exit 1 "gate: a design comment edited after the approval fails" gate --branch 26-x --pr 7
issue '["design-approved"]' the-owner $T1 null $T0 null
expect_exit 0 "gate: no size label counts as M" gate --branch 26-x --pr 7
contains "  says so" "no size label" "$LAST"
issue '["size:S"]' the-owner $T1 null $T0 null; files 150
expect_exit 0 "gate: an S PR within the threshold passes without approval" gate --branch 26-x --pr 7
contains "  lock files are not counted" "150 lines" "$LAST"
files 250
expect_exit 1 "gate: an S PR over the threshold fails" gate --branch 26-x --pr 7
contains "  says to resize" "size:M" "$LAST"

echo "- pull request shape and accepted ADRs (#21)"
issue '["size:S"]' the-owner $T1 null $T0 null; files 10
expect_exit 0 "pr gate: a well-formed S PR passes" gate --branch 26-x --pr 7
grep -q -- '--paginate' "$G/log" && ok "  reads every page of the file list" || bad "  one page only" "$(grep files "$G/log")"
expect_exit 1 "pr gate: a branch without an issue number fails" gate --branch feature-x --pr 7
contains "  names the way out" "kit start" "$LAST"
jq '.data.repository.issue.state = "CLOSED"' "$G/gate-issue.json" > "$G/i" && mv "$G/i" "$G/gate-issue.json"
expect_exit 1 "pr gate: a closed issue fails" gate --branch 26-x --pr 7
contains "  says the issue is closed" "#26 is closed" "$LAST"
issue '["size:S"]' the-owner $T1 null $T0 null
pr "add x"; expect_exit 1 "pr gate: a title without type(GH-n) fails" gate --branch 26-x --pr 7
contains "  with the command that renames it" "gh pr edit 7 --title" "$LAST"
pr "feat(GH-25): add x"; expect_exit 1 "pr gate: a title naming another issue fails" gate --branch 26-x --pr 7
pr "update(GH-26): add x"; expect_exit 1 "pr gate: a type outside Conventional Commits fails" gate --branch 26-x --pr 7
pr "feat(GH-26): add x" "${GOOD_BODY%ADR: none}"; expect_exit 1 "pr gate: a body without an ADR line fails" gate --branch 26-x --pr 7
contains "  names the line" "ADR: none" "$LAST"
pr "feat(GH-26): add x" "${GOOD_BODY/ADR: none/ADR: none — a process change, decided in ADR-0001}"
expect_exit 0 "pr gate: an ADR line with a reason after it passes" gate --branch 26-x --pr 7
pr "feat(GH-26): add x" "${GOOD_BODY/ADR: none/ADR: maybe}"; expect_exit 1 "pr gate: an ADR line that names no ADR fails" gate --branch 26-x --pr 7
pr "feat(GH-26): add x" "${GOOD_BODY/Self-review: fine./}"; expect_exit 1 "pr gate: a Review section with only the hint fails" gate --branch 26-x --pr 7
contains "  names the section" "Review" "$LAST"
pr "feat(GH-26): add x" "${GOOD_BODY/\#\# User-level test/\#\# Testing}"; expect_exit 1 "pr gate: a missing User-level test section fails" gate --branch 26-x --pr 7
contains "  names the section" "User-level test" "$LAST"
pr "add x" "no sections"; expect_exit 1 "pr gate: every problem is listed, not only the first" gate --branch 26-x --pr 7
[ "$(grep -c '  FAIL  ' <<<"$LAST")" -ge 4 ] && ok "  four problems, four lines" || bad "  lines" "$LAST"
pr "feat(GH-26): add x"
adr() { jq -nc --arg s "$1" --arg f "${2:-adr/0001-a.md}" --arg p "${3:-}" \
  '{filename: $f, status: $s, additions: 1, deletions: 1} + (if $p == "" then {} else {previous_filename: $p} end)' > "$G/pr-files.json"; }
adr added adr/0005-new.md; expect_exit 0 "pr gate: a new ADR passes" gate --branch 26-x --pr 7
adr modified; expect_exit 1 "pr gate: an edited accepted ADR fails" gate --branch 26-x --pr 7
contains "  says what to do instead" "Supersedes: ADR-0001" "$LAST"
adr removed; expect_exit 1 "pr gate: a deleted accepted ADR fails" gate --branch 26-x --pr 7
adr renamed adr/0001-b.md adr/0001-a.md; expect_exit 1 "pr gate: a renamed accepted ADR fails" gate --branch 26-x --pr 7
adr modified adr/README.md; expect_exit 0 "pr gate: the ADR index is not an ADR" gate --branch 26-x --pr 7
echo '{"data":{"repository":{"issue":null}}}' > "$G/gate-issue.json"; files 10
expect_exit 1 "pr gate: a branch number that is no issue fails" gate --branch 26-x --pr 7
contains "  says so" "#26 is not an issue" "$LAST"
touch "$G/gh-fails"; expect_exit 1 "pr gate: GitHub unreachable fails" gate --branch 26-x --pr 7
grep -qE "Exception|----- Error" <<<"$LAST" && bad "  with a stack trace" "$LAST" || contains "  with what to do" "rerun the job" "$LAST"
rm -f "$G/gh-fails"; issue '["size:S"]' the-owner $T1 null $T0 null
for i in $(seq 1 101); do jq -nc --arg f "src/f$i.clj" '{filename: $f, status: "modified", additions: 2, deletions: 0}'; done > "$G/pr-files.json"
expect_exit 1 "pr gate: 101 files are counted in full" gate --branch 26-x --pr 7
contains "  202 lines" "202 lines" "$LAST"
for f in managed/ci.yml .github/workflows/selftest.yml; do
  grep -qE '^ +types: \[opened, synchronize, reopened, edited\]' "$KIT/$f" \
    && ok "$f reruns when the title or body is edited" || bad "$f misses the edited type"
done

echo "- design approval hook (fake gh)"
H="$WORK/hookrepo"; git init -q -b main "$H"; cd "$H" || exit 1
git commit -q --allow-empty -m "chore: base"; git switch -q -c 26-gate
hook() { jq -nc --arg p "$H/$1" '{tool_name: "Edit", tool_input: {file_path: $p}}' | gate --hook; }
issue '["size:M"]' the-owner $T1 null $T0 null; : > "$G/log"
contains "hook: an edit on an unapproved M branch is refused" '"permissionDecision":"deny"' "$(hook src/a.clj)"
[ -z "$(hook adr/0004-x.md)" ] && ok "hook: adr/ may be written before the approval" || bad "hook refused adr/"
n=$(wc -l < "$G/log"); hook src/b.clj >/dev/null
[ "$(wc -l < "$G/log")" = "$n" ] && ok "hook: the verdict is cached" || bad "hook asked GitHub again"
rm -rf "$(git rev-parse --git-path kit)"; issue '["design-approved","size:M"]' the-owner $T1 null $T0 null
[ -z "$(hook src/a.clj)" ] && ok "hook: an approved branch may be edited" || bad "hook refused an approved branch"
rm -rf "$(git rev-parse --git-path kit)"; touch "$G/gh-fails"
contains "hook: GitHub unreachable means refused, with the retry" "gate --g1 26" "$(hook src/a.clj)"
rm "$G/gh-fails"; git switch -q main
[ -z "$(hook src/a.clj)" ] && ok "hook: a branch without an issue is not gated" || bad "hook gated main"
cd "$P" || exit 1

echo "- user-level test in CI (#27)"
fresh "$WORK/ut"; bb $kit init --showcase Site >/dev/null 2>&1
ut() { bb -e "(spit \"kit.edn\" (pr-str (assoc (clojure.edn/read-string (slurp \"kit.edn\")) :user-test $1)))"; }
expect_exit 0 "modules: a project without :user-test" bb $kit modules
grep -qx 'user_test=false' <<<"$LAST" && ok "  leaves the step off" || bad "  user_test" "$LAST"
expect_exit 1 "user-test: without :user-test it says what to add" bb $kit user-test
contains "  the key and its shape" ":user-test {:run" "$LAST"
ut '{:artifacts "out"}'
expect_exit 1 "doctor: :user-test without :run fails" bb $kit doctor --ci
contains "  names the key" ":user-test" "$LAST"
expect_exit 1 "user-test: refuses it too" bb $kit user-test
contains "  with the same reason" ":user-test" "$LAST"
ut '{:run "true" :artifacts "../elsewhere"}'
expect_exit 1 "doctor: artifacts outside the project fail" bb $kit doctor --ci
contains "  says where they belong" "inside the project" "$LAST"
ut '{:run "true" :artifacts "/tmp/out"}'
expect_exit 1 "doctor: an absolute artifacts path fails" bb $kit doctor --ci
accepted=""
# shellcheck disable=SC2088 # a literal ~ is the case: kit.edn holds it as text
for a in . '*' '!x' 'a b' '~/x' './x'; do
  ut "{:run \"true\" :artifacts \"$a\"}"
  bb $kit doctor --ci >/dev/null 2>&1 && accepted="$accepted [$a]"
done
[ -z "$accepted" ] && ok "doctor: artifacts upload-artifact would read as a pattern fail (. * !x, a space, ~, ./)" \
  || bad "doctor accepted artifacts" "$accepted"
accepted=""
for u in '"npm test"' '{:run 5}' '{:run "  "}' '[1]'; do
  ut "$u"
  bb $kit doctor --ci >/dev/null 2>&1 && accepted="$accepted [$u]"
done
[ -z "$accepted" ] && ok "doctor: a :user-test that is not {:run \"<command>\"} fails" || bad "doctor accepted :user-test" "$accepted"
ut '{:run "mkdir -p out && echo seen > out/shot.txt && echo visitor-ok" :artifacts "out"}'
expect_exit 0 "doctor: a declared user-level test passes" bb $kit doctor --ci
expect_exit 0 "modules: a declared user-level test" bb $kit modules
grep -qx 'user_test=true' <<<"$LAST" && ok "  turns the step on" || bad "  user_test" "$LAST"
grep -qx 'user_test_artifacts=out' <<<"$LAST" && ok "  names the folder to keep" || bad "  artifacts" "$LAST"
mkdir -p sub
expect_exit 0 "user-test: runs the project's command" bash -c "cd sub && bb ../$kit user-test"
contains "  shows its output" "visitor-ok" "$LAST"
[ "$(cat out/shot.txt 2>/dev/null)" = seen ] && ok "  from the project's root" || bad "  not from the root" "$(find . -name shot.txt)"
ut '{:run "echo broken-page >&2; exit 3"}'
expect_exit 3 "user-test: a failing test fails with its own exit code" bb $kit user-test
contains "  and shows why" "broken-page" "$LAST"
expect_exit 0 "modules: without :artifacts" bb $kit modules
grep -qx 'user_test_artifacts=' <<<"$LAST" && ok "  there is nothing to upload" || bad "  artifacts" "$LAST"
steps="$(bb -e "
(require '[clj-yaml.core :as y] '[clojure.string :as str])
(let [steps (vec (get-in (y/parse-string (slurp \"$KIT/ci/action.yml\")) [:runs :steps]))
      i (first (keep-indexed (fn [i s] (when (= \"user-test\" (:id s)) i)) steps))
      run (when i (get steps i)) up (when i (get steps (inc i)))]
  (println (str \"last=\" (= i (- (count steps) 2))))
  (println (str \"gated=\" (= (:if run) \"steps.kit.outputs.user_test == 'true'\")))
  (println (str \"runs=\" (boolean (some-> (:run run) (str/includes? \"user-test\")))))
  (println (str \"upload=\" (boolean (some-> (:uses up) (str/starts-with? \"actions/upload-artifact@\")))))
  (println (str \"on-failure=\" (boolean (some-> (:if up) (str/includes? \"!cancelled()\")))))
  (println (str \"after-it=\" (boolean (some-> (:if up) (str/includes? \"steps.user-test.outcome != 'skipped'\")))))
  (println (str \"path=\" (get-in up [:with :path]))))" 2>&1)"
grep -qx 'last=true' <<<"$steps" && grep -qx 'gated=true' <<<"$steps" && grep -qx 'runs=true' <<<"$steps" \
  && ok "CI: the user-level test runs after every other check, only when kit.edn declares it" || bad "CI user-level test step" "$steps"
grep -qx 'upload=true' <<<"$steps" && grep -qx 'on-failure=true' <<<"$steps" && grep -qx 'after-it=true' <<<"$steps" \
  && grep -qxF 'path=${{ steps.kit.outputs.user_test_artifacts }}' <<<"$steps" \
  && ok "CI: its artifacts are uploaded even when it fails" || bad "CI artifacts step" "$steps"
cd "$P" || exit 1

echo "- the GitHub side: kit github and the doctor check (#33, fake gh)"
rs="$KIT/managed/github/ruleset.json"
pr_rule() { jq -c --arg k "$2" '.rules[] | select(.type == "pull_request") | .parameters[$k]' "$1"; }
[ "$(pr_rule "$rs" required_approving_review_count)/$(pr_rule "$rs" dismiss_stale_reviews_on_push)/$(pr_rule "$rs" require_code_owner_review)/$(pr_rule "$rs" required_review_thread_resolution)/$(pr_rule "$rs" allowed_merge_methods)" \
  = '1/true/true/true/["squash"]' ] \
  && [ "$(jq -c '[.enforcement, .conditions.ref_name.include, ([.rules[].type] | sort)]' "$rs")" \
       = '["active",["~DEFAULT_BRANCH"],["deletion","non_fast_forward","pull_request","required_status_checks"]]' ] \
  && ok "the managed ruleset: one approval, stale ones dismissed, code owners, threads resolved, squash only, on the default branch" \
  || bad "managed ruleset" "$(jq -c . "$rs")"
fresh "$WORK/gh33"; git remote set-url origin https://github.com/shundeev/kit-selftest.git
GD="$WORK/gh33-fake"; AC="$WORK/gh33-agent"; OC="$WORK/gh33-owner"; mkdir -p "$GD" "$AC" "$OC"
printf 'github.com:\n    user: kit-agent\n' > "$AC/hosts.yml"; printf 'github.com:\n    user: kit-owner\n' > "$OC/hosts.yml"
bb $kit init --showcase Site >/dev/null 2>&1
bb -e "(spit \"kit.edn\" (pr-str (assoc (clojure.edn/read-string (slurp \"kit.edn\")) :agent {:login \"kit-agent\" :email \"a@example.invalid\" :gh-config-dir \"$AC\"})))"
bb $kit init >/dev/null 2>&1
fgh() { env -u CLAUDECODE -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_REPOSITORY -u GHWF_REPO PATH="$KIT/test/fake-gh:$PATH" FAKE_GH_DIR="$GD" FAKE_GH_LOG="$GD/log" "$@"; }
ghk() { : > "$GD/log"; rm -f "$GD/posted-ruleset.json" "$GD/put-ruleset.json" "$GD/invitations-as"; fgh GH_CONFIG_DIR="$OC" bb $kit github "$@"; }
repo=shundeev/kit-selftest
echo '[{"id":5,"repository":{"full_name":"shundeev/kit-selftest"}}]' > "$GD/agent-invitations.json"
expect_exit 0 "github: a repository without the main ruleset gets it" ghk --yes
contains "  says so" "ruleset main: created" "$LAST"
p="$GD/posted-ruleset.json"
[ "$(pr_rule "$p" required_approving_review_count)" = 1 ] && ok "  one approving review" || bad "  review count" "$(cat "$p" 2>/dev/null)"
[ "$(jq -c '[.rules[] | select(.type == "pull_request") | .parameters.required_reviewers[] | [.reviewer.type, .reviewer.id, .minimum_approvals]]' "$p" 2>/dev/null)" = '[["Team",42,1]]' ] \
  && grep -qx "api orgs/shundeev/teams/owners" "$GD/log" && ok "  the owners team of kit.edn is the required reviewer" || bad "  required reviewers" "$(cat "$p" 2>/dev/null)"
[ "$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].context' "$p" 2>/dev/null)" = checks ] \
  && ok "  the project's check, checks, is required" || bad "  required check" "$(cat "$p" 2>/dev/null)"
[ "$(jq -c .bypass_actors "$p" 2>/dev/null)" = '[{"actor_type":"User","actor_id":1,"bypass_mode":"pull_request"}]' ] \
  && ok "  only the owner who runs it may bypass, in pull-request mode" || bad "  bypass" "$(jq -c .bypass_actors "$p" 2>/dev/null)"
grep -qx "api repos/$repo/collaborators/kit-agent -X PUT -f permission=push" "$GD/log" && ok "  the agent is invited with Write" || bad "  agent invite" "$(cat "$GD/log")"
grep -qx "api orgs/shundeev/teams/owners/repos/$repo -X PUT -f permission=push" "$GD/log" && ok "  the owners team gets Write" || bad "  team access" "$(cat "$GD/log")"
grep -qx "api user/repository_invitations/5 -X PATCH" "$GD/log" && [ "$(sort -u "$GD/invitations-as")" = "$AC|" ] \
  && ok "  the invitation is accepted as the agent, from its gh config" || bad "  accept" "$(cat "$GD/log"; cat "$GD/invitations-as" 2>/dev/null)"
jq '. + {id: 7, current_user_can_bypass: "always"} | .rules |= map(if .type == "pull_request" then .parameters.automatic_copilot_code_review_enabled = false else . end)' \
  "$p" > "$GD/ruleset.json"
echo '[{"id":7,"name":"main"}]' > "$GD/rulesets.json"; echo write > "$GD/perm-kit-agent"
echo '[{"slug":"owners","permission":"push"}]' > "$GD/teams.json"; echo '[]' > "$GD/agent-invitations.json"
expect_exit 0 "github: a rerun" ghk
contains "  changes nothing" "nothing to change" "$LAST"
grep -qE -- '-X (PUT|POST|PATCH)' "$GD/log" && bad "  wrote to GitHub" "$(cat "$GD/log")" || ok "  writes nothing, whatever fields GitHub adds"
cp "$GD/ruleset.json" "$WORK/gh33-same.json"
jq '(.rules |= map(if .type == "pull_request" then .parameters.required_approving_review_count = 0 else . end)) | .rules += [{"type":"required_signatures"}]' \
  "$WORK/gh33-same.json" > "$GD/ruleset.json"
expect_exit 1 "github: a different ruleset is not changed without --yes" ghk
contains "  names the difference" "required_approving_review_count" "$LAST"
contains "  and the rule dev-kit lacks" "required_signatures" "$LAST"
contains "  says how to apply it" "--yes" "$LAST"
[ ! -e "$GD/put-ruleset.json" ] && ok "  nothing is written" || bad "  wrote" "$(cat "$GD/put-ruleset.json")"
expect_exit 0 "github: --yes brings it back" ghk --yes
[ "$(pr_rule "$GD/put-ruleset.json" required_approving_review_count)/$(jq -c '[.rules[].type] | index("required_signatures")' "$GD/put-ruleset.json" 2>/dev/null)" = 1/null ] \
  && grep -qx "api repos/$repo/rulesets/7 -X PUT --input -" "$GD/log" && ok "  in place, as dev-kit has it" || bad "  update" "$(cat "$GD/log")"
rm "$GD/rulesets.json" "$GD/ruleset.json"
expect_exit 0 "github: --check names the required check" ghk --yes --check selftest
[ "$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].context' "$GD/posted-ruleset.json" 2>/dev/null)" = selftest ] \
  && ok "  selftest, as in dev-kit itself" || bad "  check" "$(cat "$GD/posted-ruleset.json" 2>/dev/null)"
echo '{"permissions":{"admin":false}}' > "$GD/repo.json"
expect_exit 1 "github: without admin rights it is refused" ghk --yes
contains "  says who can run it" "admin" "$LAST"
grep -qE -- '-X (PUT|POST|PATCH)' "$GD/log" && bad "  wrote to GitHub" "$(cat "$GD/log")" || ok "  and writes nothing"
rm "$GD/repo.json"
: > "$GD/log"
expect_exit 1 "github: an agent session never runs it" fgh CLAUDECODE=1 GH_CONFIG_DIR="$AC" bb $kit github --yes
contains "  says where to run it" "your own terminal" "$LAST"
[ ! -s "$GD/log" ] && ok "  without calling GitHub" || bad "  called" "$(cat "$GD/log")"
echo '[{"id":6,"invitee":{"login":"kit-agent"}}]' > "$GD/invitations.json"; echo none > "$GD/perm-kit-agent"
echo '[{"id":6,"repository":{"full_name":"shundeev/kit-selftest"}}]' > "$GD/agent-invitations.json"; mv "$AC/hosts.yml" "$WORK/gh33-hosts"
expect_exit 0 "github: with the agent logged out" ghk --yes
grep -q 'collaborators/kit-agent -X PUT' "$GD/log" && bad "  invited the agent again" "$(cat "$GD/log")" || ok "  a pending invitation is not sent again"
contains "  says how to accept it" "invitation to accept: in this terminal" "$LAST"
grep -q 'repository_invitations/6' "$GD/log" && bad "  accepted as someone else" "$(cat "$GD/log")" || ok "  and accepts nothing"
mv "$WORK/gh33-hosts" "$AC/hosts.yml"; echo '[]' > "$GD/agent-invitations.json"; rm "$GD/invitations.json"; echo write > "$GD/perm-kit-agent"
echo '[{"id":7,"name":"main"}]' > "$GD/rulesets.json"
jq '.rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks[0].context = "selftest" else . end)' \
  "$WORK/gh33-same.json" > "$GD/ruleset.json"
expect_exit 0 "github: without --check, an existing ruleset keeps its required check" ghk
contains "  so dev-kit's own selftest stays required" "nothing to change" "$LAST"
echo '[{"id":8,"name":"protect main"}]' > "$GD/rulesets.json"
expect_exit 1 "github: a ruleset under another name is not doubled" ghk --yes
contains "  says what to rename" "none named main" "$LAST"
grep -q -- '-X POST' "$GD/log" && bad "  created a second one" "$(cat "$GD/log")" || ok "  and creates none"
echo '[{"id":7,"name":"main"},{"id":9,"name":"main"}]' > "$GD/rulesets.json"
expect_exit 1 "github: two rulesets named main are refused" ghk --yes
contains "  naming both" "7, 9" "$LAST"
echo '[{"id":7,"name":"main"}]' > "$GD/rulesets.json"; cp "$WORK/gh33-same.json" "$GD/ruleset.json"; echo admin > "$GD/perm-kit-agent"
expect_exit 1 "github: an agent with more than Write is refused" ghk --yes
contains "  says why" "more than Write" "$LAST"
grep -qE -- '-X (PUT|POST|PATCH)' "$GD/log" && bad "  wrote" "$(cat "$GD/log")" || ok "  before any change"
echo none > "$GD/perm-kit-agent"; touch "$GD/write-fails"
expect_exit 1 "github: a failed write names the step" ghk --yes
contains "  and says a rerun is safe" "safe to repeat" "$LAST"
grep -q 'ExceptionInfo' <<<"$LAST" && bad "  with a stack trace" "$LAST" || ok "  without a stack trace"
rm "$GD/write-fails"; echo write > "$GD/perm-kit-agent"
echo '[{"id":5,"repository":{"full_name":"shundeev/kit-selftest"}}]' > "$GD/agent-invitations.json"; touch "$GD/accept-fails"
expect_exit 1 "github: a failed accept is no success" ghk --yes
contains "  says where to accept it" "github.com/$repo/invitations" "$LAST"
rm "$GD/accept-fails"; : > "$GD/log"; rm -f "$GD/invitations-as"
fgh GH_CONFIG_DIR="$OC" GH_TOKEN=owner-token bb $kit github --yes >/dev/null 2>&1
[ "$(sort -u "$GD/invitations-as" 2>/dev/null)" = "$AC|" ] && ok "github: the agent's calls use its config, never a GH_TOKEN of the shell" \
  || bad "agent calls" "$(cat "$GD/invitations-as" 2>/dev/null)"
echo '[]' > "$GD/agent-invitations.json"; cp kit.edn "$WORK/gh33-kit.edn"
owners() { bb -e "(spit \"kit.edn\" (pr-str (assoc (clojure.edn/read-string (slurp \"kit.edn\")) :owners $1)))"; }
owners '["kit-owner"]'
expect_exit 1 "github: a reviewer dev-kit no longer sets is shown before it goes" ghk
contains "  as a change" "required_reviewers" "$LAST"
owners '["other-org/owners"]'
expect_exit 1 "github: a team of another organization is refused" ghk --yes
contains "  names it" "other-org" "$LAST"
cp "$WORK/gh33-kit.edn" kit.edn
# At a terminal (#91): the answer typed at "Apply these changes?", through a pseudo-terminal. Yes is read as
# Linux's rpmatch(3) reads it: ^[yY] always, and the locale's yesexpr. A fake `locale` stands in for a Russian
# one, which CI does not have.
RUL="$WORK/ru-locale"; mkdir -p "$RUL"; printf '#!/bin/sh\necho "^[+1yYДд]"\n' > "$RUL/locale"; chmod +x "$RUL/locale"
pty() { # pty <answer> [dir put first on PATH]
  : > "$GD/log"; rm -f "$GD/posted-ruleset.json"
  printf '%s\n' "$1" | script -qec "env -u CLAUDECODE -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_REPOSITORY -u GHWF_REPO LC_ALL=C.UTF-8 TERM=xterm PATH='${2:+$2:}$KIT/test/fake-gh:$PATH' FAKE_GH_DIR='$GD' FAKE_GH_LOG='$GD/log' GH_CONFIG_DIR='$OC' bb $kit github" /dev/null 2>&1
}
answers() { # answers <want: yes|no> <locale dir or ""> <answer…>: the answers that came out otherwise
  local want="$1" dir="$2" a odd=""; shift 2
  for a in "$@"; do
    out="$(pty "$a" "$dir")"
    if [ -s "$GD/posted-ruleset.json" ]; then [ "$want" = yes ] || odd="$odd [$a]"; else [ "$want" = no ] || odd="$odd [$a]"; fi
  done
  echo "$odd"
}
rm -f "$GD/rulesets.json" "$GD/ruleset.json"
odd="$(answers yes "" y Y yes Yeah)"; [ -z "$odd" ] && ok "github: y, Y, yes, Yeah apply, in any locale" || bad "github: not taken as yes:$odd"
odd="$(answers no "" у д да n x)"; [ -z "$odd" ] && ok "github: у, д, да, n, x apply nothing in a C locale" || bad "github: taken as yes:$odd"
odd="$(answers yes "$RUL" д Да + 1 y)"; [ -z "$odd" ] && ok "github: in a Russian locale д, Да, +, 1 and y apply, as its yesexpr says" || bad "github ru: not taken:$odd"
odd="$(answers no "$RUL" у н нет)"; [ -z "$odd" ] && ok "github: у, н, нет apply nothing in a Russian locale either" || bad "github ru: taken as yes:$odd"
out="$(pty у)"
grep -q '«у»' <<<"$out" && grep -q 'nothing was changed' <<<"$out" \
  && ok "github: an answer it did not take is named" || bad "github: unnamed answer" "$out"

echo '[{"id":7,"name":"main"}]' > "$GD/rulesets.json"
jq '. + {current_user_can_bypass: "never"}' "$WORK/gh33-same.json" > "$GD/ruleset.json"
dk() { : > "$GD/log"; fgh GH_CONFIG_DIR="${1:-$AC}" bb $kit doctor 2>&1; }
out="$(dk)"
grep -q "api repos/$repo/rulesets" "$GD/log" && ! grep -q 'kit github' <<<"$out" \
  && ok "doctor: as the agent, a repository with the ruleset and Write passes" || bad "doctor GitHub side" "$out"
jq '. + {current_user_can_bypass: "always"}' "$WORK/gh33-same.json" > "$GD/ruleset.json"
out="$(dk)"; grep -E '^  FAIL .*can bypass' <<<"$out" | grep -q 'kit github' && ok "doctor: a bypass for the agent fails, with kit github as the fix" || bad "doctor bypass" "$out"
jq '. + {current_user_can_bypass: "never"} | .rules |= map(select(.type != "pull_request"))' "$WORK/gh33-same.json" > "$GD/ruleset.json"
out="$(dk)"; grep -qE '^  FAIL .*approving review' <<<"$out" && ok "doctor: a ruleset without the review rule fails" || bad "doctor review rule" "$out"
echo '[]' > "$GD/rulesets.json"
out="$(dk)"; grep -qE '^  FAIL .*no main ruleset' <<<"$out" && ok "doctor: a repository without the ruleset fails" || bad "doctor no ruleset" "$out"
echo '[{"id":7,"name":"main"}]' > "$GD/rulesets.json"; jq '. + {current_user_can_bypass: "never"}' "$WORK/gh33-same.json" > "$GD/ruleset.json"
echo read > "$GD/perm-kit-agent"
out="$(dk)"; grep -qE '^  FAIL .*permission is read' <<<"$out" && ok "doctor: an agent without Write fails" || bad "doctor permission" "$out"
echo write > "$GD/perm-kit-agent"; touch "$GD/gh-fails"
out="$(dk)"; grep -qE '^  WARN .*could not be read' <<<"$out" && ! grep -qE '^  FAIL .*ruleset' <<<"$out" \
  && ok "doctor: offline, the GitHub side is a warning" || bad "doctor offline" "$out"
rm "$GD/gh-fails"
out="$(dk "$OC")"; grep -q rulesets "$GD/log" && bad "doctor: checked the GitHub side as the owner" "$(cat "$GD/log")" \
  || ok "doctor: as anyone but the agent, the GitHub side is not judged"
: > "$GD/log"; fgh GH_CONFIG_DIR="$AC" bb $kit doctor --ci >/dev/null 2>&1
grep -q rulesets "$GD/log" && bad "doctor --ci read the rulesets" || ok "doctor --ci skips it"
cd "$P" || exit 1

echo "- pinned actions (#7)"
unpinned="$(grep -hE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^.[:space:]]' "$KIT/managed/ci.yml" "$KIT/ci/action.yml" "$KIT"/.github/workflows/*.yml \
  | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)"
if [ -z "$unpinned" ]; then ok "every external action is pinned to a commit"; else bad "actions not pinned to a commit" "$unpinned"; fi

echo "- formatting hook (#61)"
fmt() { jq -nc --arg f "$1" '{tool_input:{file_path:$f}}' | bash .shared/claude/hooks/format.sh; }
FP="$WORK/fmt"; mkdir -p "$FP/proj/src" "$FP/bare"
long='(defn f [a b] (let [x (+ a b) y (* a b) z (str "a string that makes this form much wider than one hundred twenty" x y)] (println x y z)))'
if command -v zprint >/dev/null; then
  cp "$KIT/clojure/.zprint.edn" "$FP/proj/.zprint.edn"
  printf '%s\n' "$long" > "$FP/proj/src/a.clj"; printf '%s\n' "$long" > "$FP/bare/b.clj"
  out="$(fmt "$FP/proj/src/a.clj")"
  w="$(awk '{ if (length > m) m = length } END { print m }' "$FP/proj/src/a.clj")"
  if [ -z "$out" ] && [ "$w" -gt 80 ] && [ "$w" -le 120 ]; then
    ok "formats with the project's .zprint.edn (width 120, not zprint's 80)"
  else bad "not formatted with the project's configuration" "$(cat "$FP/proj/src/a.clj")"; fi
  fmt "$FP/bare/b.clj"
  if [ "$(cat "$FP/bare/b.clj")" = "$long" ]; then ok "no .zprint.edn above the file: left as written"
  else bad "formatted without a project configuration" "$(cat "$FP/bare/b.clj")"; fi
else
  echo "  skip  formatting hook: zprint is not installed"
fi
expect_exit 0 "formatting hook: a file that is not Clojure is left alone" bash -c "echo '{\"tool_input\":{\"file_path\":\"/x/a.md\"}}' | bash .shared/claude/hooks/format.sh"
jq -e '[.hooks.PostToolUse[].hooks[].command | select(test("format.sh"))] | length == 1' .claude/settings.json >/dev/null \
  && ok "settings run the formatting hook after edits" || bad "no formatting hook in the settings"
[ "$(readlink "$KIT/.zprint.edn")" = clojure/.zprint.edn ] && ok "dev-kit formats itself with its own configuration" || bad "dev-kit has no root .zprint.edn link"

echo "- friction recorder (#55)"
FR="$WORK/state"; mkdir -p "$FR"
rec() { XDG_STATE_HOME="$FR" CLAUDE_PROJECT_DIR="$P" bash .shared/claude/hooks/friction.sh "$1"; }
flog() { cat "$FR"/dev-kit/friction/*.jsonl 2>/dev/null; }
# A worktree on an issue branch, reached by a literal path.
TW="$WORK/tw"; git init -q -b 42-some-task "$TW"; git -C "$TW" remote add origin git@github.com:u473t8/fake.git
out="$(jq -nc --arg c "cd $TW && git status" \
  '{session_id:"s1",prompt_id:"p1",tool_name:"Bash",tool_use_id:"t1",tool_input:{command:$c},cwd:"/"}' | rec PreToolUse)"
if [ -z "$out" ]; then ok "recorder prints nothing"; else bad "recorder printed" "$out"; fi
contains "a command's task: the branch and origin of its literal cd" \
  '"id":"t1","input":{"command":"cd '"$TW"' && git status"},"branch":"42-some-task","origin":"u473t8/fake"' "$(flog)"
jq -nc --arg f "$TW/new/dir/a.clj" '{session_id:"s1",prompt_id:"p1",tool_name:"Write",tool_use_id:"t2",tool_input:{file_path:$f},cwd:"/"}' \
  | rec PreToolUse
contains "a file's task: the branch of the nearest directory that exists" '"id":"t2"' "$(grep 42-some-task <<<"$(flog)")"
jq -nc '{session_id:"s1",prompt_id:"p1",tool_name:"Bash",tool_input:{command:"gh api x"}}' | rec PermissionRequest
contains "a window keeps the ask rules in force" '"Bash(gh pr merge *)"' "$(grep PermissionRequest <<<"$(flog)")"
jq -nc '{session_id:"s1",prompt_id:"p1",prompt:"трение: x"}' | rec UserPromptSubmit
contains "the owner's message is kept" '"prompt":"трение: x"' "$(flog)"
jq -nc '{session_id:"s1",prompt_id:"p1",last_assistant_message:"Done.\nneeds input: the label"}' | rec Stop
contains "a stop notes that the agent asked the owner" '"needs_input":true' "$(grep '"Stop"' <<<"$(flog)")"
if grep -q 'the label' <<<"$(flog)"; then bad "the agent's message was kept"; else ok "the agent's message is not kept"; fi
expect_exit 0 "garbage on stdin: exit 0" bash -c "echo 'not json' | XDG_STATE_HOME='$FR' bash .shared/claude/hooks/friction.sh PreToolUse"
expect_exit 0 "an unwritable log: exit 0" bash -c "echo '{}' | XDG_STATE_HOME=/proc/no bash .shared/claude/hooks/friction.sh Stop"
if [ "$(stat -c %a "$FR/dev-kit/friction")" = 700 ] && [ "$(stat -c %a "$FR"/dev-kit/friction/*.jsonl | sort -u)" = 600 ]; then
  ok "the log is the owner's alone (700, 600)"; else bad "log permissions" "$(ls -la "$FR/dev-kit/friction")"; fi
jq -nc --arg c "D=$WORK; cd \$D/tw && git status" '{session_id:"s1",tool_name:"Bash",tool_use_id:"t5",tool_input:{command:$c},cwd:"/"}' | rec PreToolUse
contains "a cd through a variable set in the same command" '"branch":"42-some-task"' "$(grep '"t5"' <<<"$(flog)")"
jq -nc '{session_id:"s1",tool_name:"Bash",tool_use_id:"t6",tool_input:{command:"cd ${TWDIR} && git status"},cwd:"/"}' \
  | TWDIR="$TW" XDG_STATE_HOME="$FR" CLAUDE_PROJECT_DIR="$P" bash .shared/claude/hooks/friction.sh PreToolUse
contains "a cd through an environment variable" '"branch":"42-some-task"' "$(grep '"t6"' <<<"$(flog)")"
TS="$WORK/my tw"; git init -q -b 43-space-task "$TS"; git -C "$TS" remote add origin git@github.com:u473t8/fake.git
jq -nc --arg c "cd \"$TS\" && git status" '{session_id:"s1",tool_name:"Bash",tool_use_id:"t3",tool_input:{command:$c},cwd:"/"}' | rec PreToolUse
contains "a quoted cd path with a space" '"branch":"43-space-task"' "$(grep '"t3"' <<<"$(flog)")"
jq -nc --arg w "$TW" '{session_id:"s1",tool_name:"Bash",tool_use_id:"t4",tool_input:{command:"cd /no/such/dir && ls"},cwd:$w}' | rec PreToolUse
contains "a cd to no directory falls back to the cwd" '"branch":"42-some-task"' "$(grep '"t4"' <<<"$(flog)")"
echo '{broken' > "$P/.claude/settings.local.json"
jq -nc '{session_id:"s1",prompt_id:"p2",tool_name:"Bash",tool_input:{command:"gh api y"}}' | rec PermissionRequest
contains "a broken settings file does not lose the other rules" '"Bash(gh pr merge *)"' "$(grep '"p2"' <<<"$(flog)")"
rm "$P/.claude/settings.local.json"
FC="$WORK/state-parallel"; big="$(head -c 30000 /dev/zero | tr '\0' x)"
for i in $(seq 1 40); do
  jq -nc --arg c "$big" --arg i "$i" '{session_id:"c",tool_name:"Write",tool_use_id:$i,tool_input:{file_path:"/nowhere/f",content:$c}}' \
    | XDG_STATE_HOME="$FC" bash .shared/claude/hooks/friction.sh PreToolUse &
done; wait
whole=$(jq -c . "$FC"/dev-kit/friction/*.jsonl 2>/dev/null | wc -l)
if [ "$(wc -l < "$FC"/dev-kit/friction/*.jsonl)" = 40 ] && [ "$whole" = 40 ]; then ok "40 parallel calls with 30 KB inputs: 40 whole lines"
else bad "parallel appends broke lines ($whole whole)"; fi
if [ "$(jq -r '.input.content | length' "$FC"/dev-kit/friction/*.jsonl | sort -n | tail -1)" -le 2100 ]; then ok "long strings are cut to 2 KB"
else bad "long strings kept whole"; fi
touch -d '200 days ago' "$FR/dev-kit/friction/2026-01.jsonl"
jq -nc '{session_id:"s1"}' | rec Stop
if [ -e "$FR/dev-kit/friction/2026-01.jsonl" ]; then bad "a log file older than 100 days was kept"
else ok "a stop drops log files older than 100 days"; fi
missing=""
for e in PreToolUse PermissionRequest PostToolUse PostToolUseFailure PermissionDenied UserPromptSubmit Stop SubagentStop StopFailure; do
  jq -e --arg e "$e" '[.hooks[$e][]?.hooks[].command | select(test("friction.sh"))] | length == 1' .claude/settings.json >/dev/null \
    || missing="$missing $e"
done
if [ -z "$missing" ]; then ok "settings register the recorder on the nine events"; else bad "settings: no recorder on$missing"; fi
jq -nc '{session_id:"s1",prompt_id:"p1",tool_name:"Bash",tool_use_id:"t9",tool_input:{command:"gh issue create --title x"}}' \
  | XDG_STATE_HOME="$FR" CLAUDE_PROJECT_DIR="$P" bash .claude/hooks/pretooluse.sh > "$WORK/deny.out"
contains "the entry hook still prints the refusal" '"permissionDecision":"deny"' "$(cat "$WORK/deny.out")"
contains "a hook's refusal is recorded with its call" '"event":"HookDenied"' "$(grep '"t9"' <<<"$(flog)")"

echo "- retrospective gate (#56, fake gh)"
MG="$WORK/missing"; mkdir -p "$MG"
missing() { jq -n '{data: {search: {nodes: [
  {number: 31, title: "Has its retro", comments: {nodes: [{body: "## Retrospective\n\nx"}]},
   closedByPullRequestsReferences: {nodes: [{mergedAt: "2026-11-10T10:00:00Z"}]}},
  {number: 32, title: "Lacks its retro", comments: {nodes: [{body: "done"}]},
   closedByPullRequestsReferences: {nodes: [{mergedAt: "2026-11-11T10:00:00Z"}]}},
  {number: 33, title: "Closed without a PR", comments: {nodes: []}, closedByPullRequestsReferences: {nodes: []}}]}}}' > "$MG/missing.json"; }
fake() { env PATH="$KIT/test/fake-gh:$PATH" FAKE_GH_DIR="$MG" FAKE_GH_LOG="$MG/log" "$@"; }
missing
expect_exit 1 "retro --missing names a merged issue without its retrospective" fake bb "$KIT/bin/kit" retro --missing --repo u473t8/fake
contains "  the issue" "#32 Lacks its retro" "$LAST"
contains "  the command that collects its data" "kit retro 32" "$LAST"
if grep -qE '#31|#33' <<<"$LAST"; then bad "  named one with a retrospective or without a PR" "$LAST"; else ok "  not those with a retrospective or without a PR"; fi
jq '.data.search.nodes |= map(select(.number != 32))' "$MG/missing.json" > "$MG/m" && mv "$MG/m" "$MG/missing.json"
expect_exit 0 "retro --missing: every merged issue has its retrospective" fake bb "$KIT/bin/kit" retro --missing --repo u473t8/fake
if [ -z "$LAST" ]; then ok "  prints nothing"; else bad "  printed" "$LAST"; fi
missing; : > "$MG/log"
expect_exit 1 "start refuses new work while a merged issue lacks its retrospective" \
  fake bb .shared/bin/kit start --title x --priority High
contains "  names it" "#32" "$LAST"
contains "  names the owner's waiver" "--skip-retro" "$LAST"
if grep -q '^issue create' "$MG/log"; then bad "  created an issue"; else ok "  created nothing"; fi
: > "$MG/log"
fake bb .shared/bin/kit start --title x --priority High --skip-retro >/dev/null 2>&1
if grep -q 'search(' "$MG/log"; then bad "--skip-retro still checked"; else ok "--skip-retro passes the check"; fi
touch "$MG/gh-fails"
out="$(fake bb .shared/bin/kit start --title x --priority High 2>&1)"
contains "GitHub unreachable: the start script says it could not check" "could not check" "$out"
rm "$MG/gh-fails"
contains "a session starts by naming merged issues without a retrospective" "#32" \
  "$(fake bash .shared/claude/hooks/session-start.sh 2>&1)"
if jq -e '.permissions.ask | index("Bash(* --skip-retro*)")' .claude/settings.json >/dev/null; then ok "--skip-retro asks the owner"
else bad "no ask rule for --skip-retro"; fi

echo "- retrospective data (fake gh, friction log)"
RT="$WORK/retro"; mkdir -p "$RT/state/dev-kit"; cp -r "$KIT/test/fixtures/retro/friction" "$RT/state/dev-kit/"
retro() { PATH="$KIT/test/fake-gh:$PATH" FAKE_GH_DIR="$RT" FAKE_GH_LOG="$RT/log" GITHUB_REPOSITORY=u473t8/fake \
            XDG_STATE_HOME="$RT/state" bb "$KIT/bin/kit" retro "$@"; }
# Issue #55 of u473t8/fake: design comment 10:00, approved 10:20, PR #58 opened 12:30, approved 13:30, merged 14:00.
# The log (test/fixtures/retro/friction): its branch 55-count-friction, another task's 61-other-task, a turn that
# names no task, another project (session s2), October outside the 14 days, a half-written last line.
jq -n --arg agent "$default_login" '{data: {repository: {issue: {
  number: 55, createdAt: "2026-11-12T09:30:00Z", closedAt: "2026-11-12T14:00:00Z",
  labels: {nodes: [{name: "design-approved"}, {name: "size:M"}]},
  timelineItems: {nodes: [{label: {name: "design-approved"}, actor: {login: "the-owner"}, createdAt: "2026-11-12T10:20:00Z"}]},
  comments: {nodes: [{author: {login: $agent}, body: "## Design\n\nx", createdAt: "2026-11-12T10:00:00Z"}]},
  closedByPullRequestsReferences: {nodes: [{number: 58, headRefName: "55-count-friction",
    createdAt: "2026-11-12T12:30:00Z", mergedAt: "2026-11-12T14:00:00Z", additions: 120, deletions: 10, changedFiles: 4,
    commits: {nodes: [{commit: {authoredDate: "2026-11-12T11:00:00Z", statusCheckRollup: {state: "SUCCESS"}}},
                      {commit: {authoredDate: "2026-11-12T12:25:00Z", statusCheckRollup: {state: "FAILURE"}}}]},
    reviews: {nodes: [{author: {login: "the-owner"}, state: "COMMENTED", submittedAt: "2026-11-12T13:00:00Z"},
                      {author: {login: $agent}, state: "COMMENTED", submittedAt: "2026-11-12T13:10:00Z"},
                      {author: {login: "the-owner"}, state: "APPROVED", submittedAt: "2026-11-12T13:30:00Z"}]},
    timelineItems: {nodes: []},
    comments: {nodes: [{author: {login: $agent}, createdAt: "2026-11-12T12:40:00Z",
                        body: "## Что сделать руками (владелец)\n\n1. Открой\n2. Нажми\n3. Проверь"}]}}]}}}}}' > "$RT/retro.json"
expect_exit 0 "retro: prints the friction data of a merged issue" retro 55 --now 2026-11-12T17:00:00Z
out="$LAST"
contains "  the span of the task's events, its later messages included" "2026-11-12 10:00 → 2026-11-12 15:00 UTC" "$out"
contains "  windows by their ask rule: own branch, own turn, own subagent; not another task's, not a turn naming none" \
  "| Confirmation: yes | ask rule: Bash(gh api *) | 4 | 7 |" "$out"
contains "  a Read rule matches by path, printed without it" "| Confirmation: yes | ask rule: Read(…) | 1 | 1 |" "$out"
touch "$RT/silent-fail"; sil="$(retro 55 2>&1)"; rm "$RT/silent-fail"
contains "kit's own gh!: a silent failure names the call and the exit code (#95)" "gh api graphql failed with exit code 3" "$sil"
contains "  a window no ask rule explains" "| Confirmation: yes | Read (no ask rule matches) | 1 | 1 |" "$out"
contains "  a window and no run: the owner said no; Esc on a window is that no, not an interruption too" "| Confirmation: no | ask rule: Bash(rm *) | 2 | 2 |" "$out"
contains "  a question" "| Question to the owner | AskUserQuestion | 1 | 1 |" "$out"
contains "  needs input at the end of a turn" "| Question to the owner | needs input in chat | 1 | 1 |" "$out"
contains "  a plan that never ran" "| Plan for approval | declined | 1 | 1 |" "$out"
contains "  a turn without its Stop, followed by another: Esc" "| Owner interrupted (Esc) | — | 1 | 1 |" "$out"
contains "  a hook's refusal" "| Refused by a hook | gh issue create | 1 | 1 |" "$out"
contains "  the classifier's refusal, with its category" "| Refused by the classifier | git push — git_destructive | 1 | 1 |" "$out"
contains "  no run in a turn that ended normally: a deny rule; a lone echo is named" "| Refused by a rule | echo | 1 | 1 |" "$out"
contains "  a failed command" "| Tool error | bb kit gate | 1 | 1 |" "$out"
contains "  gh's flag values stay out of the shape" "| Tool error | gh pr view | 1 | 1 |" "$out"
contains "  inline code stays out of the shape" "| Tool error | python3 -c | 1 | 1 |" "$out"
contains "  the same command within minutes" "| Same command 3+ times | gh pr view | 3 | 3 |" "$out"
# The second review of #55: each case below broke the first hook-based version.
contains "  a stale identical call from an earlier turn keeps no window of a later one" "| Refused by a rule | gh api (REST) | 1 | 1 |" "$out"
contains "  a rule naming a URL prints without it" "| Confirmation: yes | ask rule: Bash(…) | 1 | 1 |" "$out"
contains "  a turn that failed is no Esc" "| Turn failed (API error) | — | 1 | 1 |" "$out"
contains "  the repository's case does not matter" "| Tool error | make | 1 | 1 |" "$out"
if grep -qF "git status" <<<"$out"; then bad "  a command 30 min apart counted as a repeat"; else ok "  repeats are runs within 10 minutes"; fi
contains "  recurring: all tasks and projects of the last 14 days, not October" "Confirmation: yes · ask rule: Bash(gh api *): 7" "$out"
contains "  another project's friction counts in the 14 days" "Tool error · npm: 3" "$out"
contains "  the owner's mark, on one line" "трение: ссылка открылась в двух браузерах" "$out"
# #65: where the task's time went. Turns run from the owner's message to Stop, StopFailure or the turn's
# last event; a Stop without a turn id is no turn.
contains "  time: the task's turns" "Time of the task: 10 turns, 42m in all" "$out"
contains "  time: waiting on the owner, windows and questions" "waiting on the owner: 7 confirmation windows, 5m; 2 questions, 24m" "$out"
contains "  time: commands, and the longest" "commands: 2m; the longest: bb kit gate 1m, git log 1m" "$out"
expect_exit 0 "retro: a task worked on only in a turn that served two tasks" retro 62 --now 2026-11-12T17:00:00Z
contains "  says the turn time is not split" "its turns also served other tasks" "$LAST"
contains "  still counts its commands" "commands: 1m; the longest: make 1m" "$LAST"
contains "  under a minute reads in seconds" "waiting on the owner: 0 confirmation windows, 0s" "$LAST"
contains "  the owner's messages: the mid-turn one, and those of turns naming no task go to the last task" "Owner messages: 10" "$out"
if grep -qE "почему так|secret|import|/w/|/tmp/|host/tok" <<<"$out"; then bad "  printed a message, a path, a flag value or code" "$out"
else ok "  no messages, paths, flag values or code"; fi
contains "GitHub: the design approval" "Design approval: 1, 20m after the first \`## Design\` comment" "$out"
contains "GitHub: the diff" "PR #58: +120 −10 in 4 files, 2 commits; Size M" "$out"
contains "GitHub: reviews by the owner" "Review rounds with comments: 1; approvals: 1; dismissed: 0" "$out"
contains "GitHub: waiting on the owner" "PR opened → Approve 1h 00m; Approve → merged 30m" "$out"
contains "GitHub: CI" "CI: 1 of 2 commits failed" "$out"
contains "GitHub: the owner's manual steps" "Owner steps: 1 comment, 3 steps" "$out"
expect_exit 0 "retro --messages lists the owner's messages locally" retro 55 --messages --now 2026-11-12T17:00:00Z
contains "  the mid-turn one too" "я про план 55" "$LAST"
expect_exit 0 "retro: a machine with no friction log" \
  env PATH="$KIT/test/fake-gh:$PATH" FAKE_GH_DIR="$RT" FAKE_GH_LOG="$RT/log" GITHUB_REPOSITORY=u473t8/fake \
  XDG_STATE_HOME="$WORK/none" bb "$KIT/bin/kit" retro 55 --now 2026-11-12T17:00:00Z
contains "  says so, GitHub still prints" "Friction log: not available" "$LAST"
contains "  GitHub's part" "PR #58" "$LAST"
touch "$RT/gh-fails"
expect_exit 0 "retro: GitHub unreachable" retro 55 --now 2026-11-12T17:00:00Z
contains "  says so" "GitHub: not available" "$LAST"
contains "  the log still counts" "| Tool error | bb kit gate | 1 | 1 |" "$LAST"
rm "$RT/gh-fails"
expect_exit 1 "retro: a --now that is not a time names the format" retro 55 --now yesterday
contains "  names the format" "2026-11-12T10:00:00Z" "$LAST"

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
