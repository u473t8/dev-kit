---
name: repo-task-delivery
description: "Use when the user reports a bug, a warning, a regression, or proposes a feature, improvement, refactor, docs or config change that is likely to end in a committed edit to this repository. Drives the task through the stages of ADR-0002: size, requirements, invariants, design and the owner's approval (G1), plan and execution, review and simplification, user-level test, pull request, merge on the owner's Approve, retrospective."
---

# Repo Task Delivery

Every task passes the same stages (ADR-0002); Size decides how much of each. The issue is the
one place a task's thinking lives: its sections, from the form `.github/ISSUE_TEMPLATE/task.yml`,
are Requirements, Invariants, Design, Plan and Done when. The pull request body follows
`.github/pull_request_template.md`.

`size → requirements → invariants → design → G1 → plan → execute → review → user-level test → PR → merge → retrospective`

## When to use

- A new problem or a proposed change that should end as a committed edit.
- Not for: questions, reading or measuring only, continuing an issue that is already active,
  or when the owner says to skip GitHub. A narrow sub-step ("open the PR") uses
  `gh-project-workflow` directly.
- "It is small" is not an exception: small changes take the light path, not no path.
- A session start that says dev-kit is behind: an XS task "Update dev-kit" in this project
  (move `.shared` to origin/main, `kit init`, commit the generated files, PR), before other work.

## 1. Size sets the ceremony

Find the issue or file it first. Search the open issues, since one issue may host several PRs.
File through `gh-project-workflow` (`kit start`), never `gh issue create`, with Priority
and Size (Priority: **Urgent**, broken for the owner now or blocking all work; **High**, the owner
waits on it or it removes recurring friction; **Medium**, a planned improvement; **Low**, nice to
have); starting work means Status **In progress**. No file is edited before the issue and its
branch exist, XS included.

| Size | Ceremony | Example |
|---|---|---|
| XS / S | Requirements and Done when in a line or two, Design "obvious", no Plan, no G1. Stages 7–11 in full. | The PR type taken from the branch's commits (#44). |
| M | Every section, and no code before G1. | The agent's own GitHub identity (#18). |
| L | Not one task: split it into S and M sub-issues (native sub-issues), each on its own path. | Moving the repositories into an organization (#22). |

Name the Size in the first reply, with a reason, before anything else: "Size M: a new flag with
a choice of what the version is." An S that grows past a screenful of logic or into a second
component is an M: stop, resize it and ask for G1.

## 2. Requirements

- Ask clarifying questions one at a time, each with two or three named options, the
  recommended one first. A question about what a person does or sees always goes to the owner.
  Before asking it, check how the platform's standard tools behave, and name that option first (#91).
- Then restate the understanding in a few lines and let the owner confirm it.
- Write **Requirements** (what is true for a person afterwards, and why) and **Done when**
  (checks a person can see, including the user-level test) into the issue.

## 3. Invariants

- List by number what must keep holding: the ADRs in force (walk the `Supersedes:` lines), the
  ADR-0001 catalogue rows that apply, the rules in `AGENTS.md`, and behaviour that must not change.
- A new invariant this work introduces is proposed as an ADR (`adr` skill), committed first on
  the branch.

## 4. Design

- Two or three real options with their trade-offs, and the chosen one. A choice that is
  expensive to reverse also becomes an ADR in the same pull request.
- Check the design against:
  - a new machine, a new repository, a new worktree, offline, and a second person (#18, #22);
  - every claim a guarantee rests on: checked as the rules say (current documentation, a run, an
    experiment when unclear), never taken from forums or memory (#22). The proven fact is written
    where the decision depends on it: in the mechanism's code or test, the process step, or the
    ADR, with links to the documentation and the evidence. There is no separate list of facts;
  - each manual step for the owner: automate it, or plan it as numbered steps in the PR;
  - work that runs on real data: a throwaway probe over that data comes before the tests and the
    code (#55, #60). What it shows goes into the design; the probe itself goes away.
- For M, post the design on the issue as a comment starting with `## Design`, and name what the
  owner decides. It answers the issue's open questions by number first (#33).

## 5. G1 — the owner approves the design (M)

- No code until the owner adds the label `design-approved` to the issue; `adr/` is the
  exception. The agent never sets the label. A design changed after approval needs a new one.
- Enforced: CI's `kit gate` fails the PR, and the edit hook refuses changes on the issue branch,
  while the approval is missing. The approval counts only when set by someone with write access
  who is not the agent, after the issue body and every `## Design` comment last changed. So a
  design and its addenda are comments starting with `## Design`.
- The gate reads the Size from the issue's `size:*` label (`kit start` sets it with the board
  field). No label counts as M. An XS/S PR over 200 changed lines fails until the issue is resized.

## 6. Plan and execute

- Before the first code of an M issue, read the approval from GitHub (`kit gate --g1 N`), not from
  memory of the chat (#93, #95).
- The Plan's numbered steps are the approved scope. A step that turns out wrong stops the work
  and goes to the owner: no silent deviation.
- Work is solved from its root causes. A new one found mid-work goes to the issue as a `## Design`
  addendum, and the code it affects is rewritten from it, not patched on (#60). The PR lists the
  root causes it rests on.
- Tests first: show each new case failing on the old code, including cases added after the
  first green run. A check that guards against a known failure shows it catches it: bring the
  failure back and see the check fail (#40).
- A rewrite of working code is checked by running the old and the new on the same inputs before
  the PR (#95).
- A loop that splits words runs through `bash -c`, not in the session's zsh (#55, #33).
- Stay inside the issue's scope. A finding outside it is a comment on the issue, or a new issue
  when a PR could close it.
- New screen or visual redesign: invoke `frontend-design:frontend-design` before the first markup.

## 7. Review and simplify

- Self-review the diff (`git diff --stat` first). For M also run `/code-review` and `/simplify`;
  for Clojure, the `smell-reviewer` agent. The PR shows, for M, the lines of code before and after
  the simplify pass (#60).
- For M, also an independent review: a separate agent gets the code and the spec, not the
  author's conclusions, and reproduces each finding (#55's two found 14 defects; #63).
- Fix or answer every finding, and list them under **Review** in the PR.

## 8. User-level test

- Check the behaviour where a person meets it: a UI in a real browser, a service through its
  requests or CLI, a script through a real run, an LLM system through its eval suite.
  What each kind asserts: `.shared/docs/user-level-tests.md`.
- When `kit.edn` declares `:user-test`, run `.shared/bin/kit user-test`: CI runs the same command
  on every pull request. A test that checks the change and is not there yet is added to it.
- A dev-kit change to CI is tested through a project PR pinned to the dev-kit branch (#27).
- The evidence goes under **User-level test**. A check that can only run after the merge
  (GitHub reads templates and rulesets from `main`) is named as such, and its result goes on
  the issue.
- Under **Verified** and **Not verified**, say exactly what was proven and what was not.

## 9. Pull request

- Write the body from `.github/pull_request_template.md`, then run `kit finish`
  (`gh-project-workflow`). It commits, pushes, opens the PR, turns on auto-merge and moves the
  card to **In review**. It first runs the shape rules CI's pull request gate holds (branch,
  title, `ADR:` line, filled **Review** and **User-level test**), so a PR that would fail them is
  never opened (#21).
- Anything the owner must do by hand goes into a PR comment that starts with `## Owner steps`, as
  numbered steps: where to click, what to type, what the result looks like, what to do if it
  fails. A step that checks a hook says "ask the agent, without `!`": a `!` command bypasses the
  hooks (site#18). The report gives the link.
- A PR that changes the same lines as one already waiting is opened as a draft until that one
  merges (#81, #27).

## 10. Review round and merge on the owner's Approve

- The owner reviews in the diff. For each thread:
  - agreed: fix it, fold the fix into the commit it belongs to (`git commit --fixup <sha>`,
    then `GIT_SEQUENCE_EDITOR=: git rebase --autosquash origin/main`), push with
    `git push --force-with-lease`, reply with the new hash and resolve the thread;
  - disagreed: reply with the argument and leave the thread open. An open thread blocks the merge.
- The owner's Approve of the latest commit is the word to merge. Auto-merge merges once the
  checks pass and the branch contains the latest `main`. Then run `kit merge` for the
  closeout; it also updates a branch that fell behind, and merging `main` in keeps the approval.
- The agent never approves a pull request.
- An owner step still open after the merge: reopen the issue and keep its card **In progress**.
  A branch from `gh issue develop` closes its issue on merge, whatever the PR body says.

## 11. Retrospective

- New work waits for it (ADR-0004, #56): `kit start` refuses to start while an issue
  merged in the last 14 days lacks its `## Retrospective` comment, and a session's start names
  them. Only the owner waives it: `--skip-retro` asks them first.
- After the merge, collect the data: `bb .shared/bin/kit retro <issue>` (in dev-kit itself
  `bb bin/kit retro <issue> --repo shundeev/dev-kit`). It counts the friction that dev-kit's hooks
  recorded as it happened, and adds GitHub's: the owner's confirmation windows by the ask rule
  behind them, questions, interruptions, the owner's «трение:» marks, refusals, tool errors,
  repeated commands, reviews, waiting, CI and manual steps. The agent cannot see a confirmation
  window, so friction comes from this table, not from memory.
- The hooks tie an event to its task by the git branch of the directory it touched. Name
  worktrees by literal paths (`cd /abs/path`, `git -C /abs/path`), not by shell variables.
- Post a `## Retrospective` comment on the issue (#28) that starts with the table. It covers the
  flow, code rules, determinism, friction, mistakes and wrong assumptions, facts learned, and what
  worked. XS and S may say "nothing to change" in one line after the table.
- A cause the table lists as recurring (3 or more in 14 days) is a finding, whatever this task's
  own count. The owner's other messages are classified locally (`--messages`: corrections,
  requests to explain, repeated asks); only counts and paraphrases are published.
- Every finding ends with a proposal, and the owner decides which become issues. A lesson that
  holds for every project goes to dev-kit, not to the agent's memory. A fact learned about GitHub
  or a tool goes where a decision depends on it (code, test, rule, ADR), or nowhere. A detail that
  can become a mechanism becomes one instead of a note.
- Follow-up work is a new task, except obvious closeout caused by the merged change: the board
  card, the branch and worktree, a live check the PR promised, a typo in the merged text. A new
  feature the change suggests is a new task.
