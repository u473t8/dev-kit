# Working rules

These rules apply to every agent working in this repository (Claude Code, Codex, OpenCode).

- When reporting verification, say exactly what was proven and what was not.
- Project structure and how to run things: README.md.
- How a tool or service behaves comes from its current official documentation for the version in
  use, never from forums or memory, and is then checked: read the documentation, run the command;
  if the result differs, read the documentation closer; if it is still unclear, run an experiment
  in a scratch setup. Nothing is taken on faith. Link the page that settled it where a decision
  depends on it.

## Delivery

- Work that is likely to end in a committed edit runs the full flow: invoke the
  `repo-task-delivery` skill and let it drive. Every task passes its stages (ADR-0002): size →
  requirements → invariants → design → the owner's `design-approved` before any code (M) →
  plan → review and simplify → user-level test → PR → merge on the owner's Approve →
  retrospective.
  Name the task's Size (XS/S/M/L) and the reason in the first reply; it sets the ceremony.
  No file is edited before the issue and its branch exist, XS included. The design approval is
  enforced: CI (`kit gate`) and the edit hook refuse code on an M issue without it.
- Issues are filed by `.shared/bin/kit start`,
  never by hand: it puts the issue on the board with Status, Priority and Showcase and creates
  its branch. An issue that is not on the board does not exist.
- Priority is Urgent / High / Medium / Low. Judge it; never leave it empty.
- Branches come from `gh issue develop` (`kit start`), named `<number>-<slug>`.
  Never `git checkout -b` / `git switch -c`.
- Never push to `main`; it accepts pull requests only. A pull request merges only on the
  owner's Approve of its latest commit and only on top of the latest `main`; the ruleset
  enforces both. The agent never approves. Auto-merge, turned on by `kit finish`, merges
  once both hold; `kit merge` brings a branch that fell behind up to date (merging
  `main` in keeps the approval) and closes out.
- Not part of the flow: answering a question, reading or measuring, continuing an issue that is
  already active, or the owner saying to skip GitHub.
- A refusal from a hook or a permission rule stops the work and goes to the owner: what you
  were doing, what was refused, the refusal verbatim. Do not look for a way around it.
  If the owner asks for a blocked command outright, prefix it with `DELIVERY_GUARD=off`;
  never do that on your own judgement.

## Working with the owner

- A report to the owner says what changed for them and what is needed from them, in plain words,
  item by item; the details stay in the PR. No jargon tables.
- A report on a new mechanism starts with the problem it solves and what changes for the owner,
  then says how it works (#63).
- Every report after a push ends with the pull request's link.
- Anything the owner has to do by hand (a setting, a login, a click) goes into a PR comment
  starting `## Owner steps`, as numbered steps: where to click, what to type, what the result
  looks like, what to do if it fails. The report gives only the link; with no PR yet, open a draft
  PR first. When several PRs need the owner, one step per PR, each named by its title.
- Every error a tool, script or hook prints says what to do: to the agent, or to the owner when
  only a person can. When the fix is mechanical, the code does it itself.
- A lesson or preference that holds for every project goes into dev-kit through an issue and a PR,
  not only into an agent's memory.
- A message from the owner that starts with «трение:» (or "friction:") registers friction. Answer
  it in one line and go on; `kit retro` collects it for the task's retrospective.

## Decisions

- A decision about what a person does or sees cannot be settled by the code. Name it before
  the first artifact and ask the owner in one line with two named options. Until answered, it
  is a line in the issue.
- A choice between alternatives that are expensive to reverse is recorded as an ADR in the
  same pull request (`adr` skill). Every PR body carries an `ADR:` line.
- New screen or visual redesign: invoke `frontend-design:frontend-design` before building it.

## Issues

- The repository is public. Never put secrets or the state of a live system (what is broken,
  what a password is not) into issues, PRs, commits or docs.
- An issue exists only for work a pull request can close, a bug, or a decision worth recording.
  Findings, measurements and notes are comments on the existing issue.
- Search open issues before filing. One issue may host several PRs.
- Dependencies use the native blocked-by relation. A chain deeper than A needs B needs C is
  planning disguised as tracking — merge the nodes.

## Commits

PRs merge by squash; these rules govern the branch history the reviewer reads.

- Subject: Conventional Commits with the issue in the scope — `feat(GH-12): add landing page`.
  Types: feat, fix, docs, refactor, test, perf, build, ci, chore.
- A branch carries as few commits as its changes need. Each is one self-contained change that
  builds and passes on its own.
- Unrelated changes never share a commit; one change is never split across several.
- No fixup, typo, WIP or "address review" commits survive to the merge: fold them with
  `git commit --fixup <sha>` + `GIT_SEQUENCE_EDITOR=: git rebase --autosquash main`.
- Rewritten history goes out with `git push --force-with-lease`, to your own issue branch only (#38).

## After the merge

- A merged issue gets a retrospective comment (stage 11). Follow-up work is a new task, except
  obvious closeout caused by the merged change.

## Token hygiene

- `git diff --stat` before a full diff; then diff only the files you need. History: `git log --oneline -20`.
- Hand subagents file paths, not pasted contents.
- Long logs and CI output go to the `log-reader` agent; mechanical board/git chores to `ops`.
