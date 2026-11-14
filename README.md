# dev-kit

How I run engineering work with AI agents across my repositories: one set of agent rules, skills,
hooks, format settings and CI checks, mounted into every project as a git submodule.

Every task takes the same path, and the path is enforced, not only written down:

```
issue on the board → design approved by the owner (size M and up) → branch → tests first
→ PR → the owner's Approve → auto-merge → retrospective
```

Hooks refuse:
- an issue filed outside the board, and a PR from a branch with no issue;
- an edit before an M-sized design is approved;
- new work while a merged task lacks its retrospective;
- destructive commands (`git reset --hard`, `git push -uf`, `rm -rf` outside the project) and secret reads (`.env`, `~/.ssh`), through [cc-safety-net](https://github.com/kenryu42/cc-safety-net), vendored at a pinned version (`vendor/cc-safety-net`).

The `main` ruleset accepts pull requests only, with the owners' approval.

## Add it to a project

```sh
git submodule add https://github.com/shundeev/dev-kit .shared
.shared/bin/kit init --showcase <board Showcase option> [--modules clojure] [--scaffold]
git add -A && git commit -m "chore: add dev-kit"
.shared/bin/kit github   # in your own terminal: the main ruleset and the agent's Write access
```

- **A clone:** `git clone --recurse-submodules …`, then `.shared/bin/kit init`.
- **A new machine:**
  1. Install `git`, `gh`, `bb` (babashka), `jq`, Node 22 or later and Claude Code.
  2. Log yourself in with `gh auth login`.
  3. Run `.shared/bin/kit init` in your own terminal. It also logs the agent's GitHub account in; see [the agent's identity](docs/agent-identity.md).

## Commands

`kit` is `.shared/bin/kit` in a project.

| Command | What it does |
|---|---|
| `kit init` | Lays everything out. It is safe to rerun and never overwrites project-owned files: a file of the project's own where dev-kit writes stops it with what to move, and nothing is written until `kit.edn` is valid. A `.claude/settings.json` found at the first run moves into `kit.edn` as `:claude-settings`. `--local` touches only the per-machine items; the session start runs it. |
| `kit doctor` | Checks that everything is in place and matches the pinned dev-kit, that `kit.edn` is valid, and that no `CLAUDE.md` hides AGENTS.md from Claude Code. Read as the agent, it also checks the GitHub side: the `main` ruleset requires an approving review, the agent cannot bypass it, and the agent has Write. Each problem comes with the command that fixes it. `--ci` skips the local-only checks. |
| `kit github` | Run by the owner in their own terminal, since it takes an admin: brings the repository's `main` ruleset to `managed/github/ruleset.json`, with the project's required check (`--check`, default `checks`), the `:owners` teams as required reviewers and the owner as the only bypass actor, in pull-request mode. It gives the agent and `:owners` Write and accepts the agent's invitation as the agent. It shows each change and applies it on a yes, or with `--yes`; a rerun changes nothing. |
| `kit hook '<command>'` | What the project's entry hook (`.claude/hooks/pretooluse.sh`) says to one Bash command, fed in the shape Claude Code sends it, without running the command: `allowed` (exit 0), `refused: <reason>` (exit 2) or `asks: <reason>` (exit 3). A hand check is no friction: nothing is written to the friction log. |
| `kit retro N` | The friction data of merged issue N, for its retrospective. From the friction log the hooks keep on this machine (`~/.local/state/dev-kit/friction`, never committed): confirmation windows by the rule behind them, questions, interruptions, «трение:» marks, refusals, errors, repeated commands and where the time went. From GitHub: reviews, waiting on the owner and CI. Counts only. |
| `kit retro --missing` | Merged issues of the last 14 days without a retrospective. New work waits for them. |
| `kit gate …` | The pull request gate: the branch of an open issue, the title, the `ADR:` line, filled **Review** and **User-level test**, accepted ADRs unchanged, the design approval and the size. CI runs it, again when a title or body is edited; the finish script runs its shape rules before it opens a PR; the edit hook runs the design approval. |
| `kit user-test` | The project's user-level test, `:user-test` in `kit.edn`, run from the project's root. CI runs it after the other checks and keeps its artifacts, also when it fails ([docs/user-level-tests.md](docs/user-level-tests.md)). |
| `kit start`, `kit finish`, `kit merge` | The delivery flow's GitHub steps: the issue on the board and its branch; the commit, push, pull request and In review; the closeout after the owner's Approve. `kit board set` sets one card's field. How to use them: the `gh-project-workflow` skill. |
| `kit identity`, `kit modules` | The agent's identity alone, for a repository without dev-kit; the modules, for CI. |

## How updates arrive

A project pins one dev-kit commit. To move it:

```sh
git submodule update --remote .shared && .shared/bin/kit init
```

Then open a pull request "chore: update dev-kit". `kit init` rewrites the managed files to match.

You do not have to watch for updates: the session start says when the pinned commit is behind dev-kit's `main`, and the agent opens the update as an XS task.

## What a project gets

- **Scaffold**, created once when missing and owned by the project from then on:
  - `kit.edn`, `LICENSE` (MIT), and the project part of `AGENTS.md`;
  - with `--scaffold`, also `README.md`, `adr/` and `docs/experiments/`.
- **Managed**, owned by dev-kit: `init` rewrites these files, and `doctor` checks them locally, at session start and in CI.

| In the project | Comes from |
|---|---|
| `AGENTS.md`, between `dev-kit:begin` / `dev-kit:end` | `rules/shared.md` (+ `rules/clojure.md`) |
| `.claude/settings.json`: permissions and hooks (safety guard, delivery guard, friction recorder, formatting) | `claude/settings.base.json` + board settings from `kit.edn` |
| `.cc-safety-net/policy.json`: the safety guard's policy, read by Claude Code, Codex and OpenCode alike | `kit` (level `standard`) |
| `.claude/skills/*` (links) | `claude/skills/`: `repo-task-delivery`, `gh-project-workflow`, `adr` |
| `.claude/agents/*.md` (copies) | `claude/agents/`: `ops`, `log-reader`; `smell-reviewer` with the Clojure module |
| `.github/workflows/ci.yml` | `managed/ci.yml`, which runs `ci/action.yml` from the submodule |
| `.github/ISSUE_TEMPLATE/task.yml`, `.github/pull_request_template.md` | `managed/github/` |
| `.github/CODEOWNERS` | `:owners` in `kit.edn` |
| git `core.hooksPath` | `githooks/`: the zprint check before a commit; in dev-kit itself also CI's shellcheck line before a push (a project's push is not touched) |
| `.zprint.edn`, `.clj-kondo/config.edn` `:config-paths` | `clojure/` (module `clojure`) |
| `env` in `.claude/settings.local.json` (per machine, git-ignored) | `:agent` in `kit.edn` / `kit-defaults.edn` |

**The board's link under the prompt** comes from the `project-link` plugin (`claude/plugins/`). The generated settings declare `.shared` as a plugin marketplace, so Claude Code loads it at the session start with nothing to install, at the dev-kit version the project pins (#30).

**Why `AGENTS.md` and not `CLAUDE.md`.** It is one file for every agent. Claude Code reads `AGENTS.md` when there is no `CLAUDE.md`, and Codex and OpenCode read it natively. The shared rules are written into it as text, because only Claude Code understands `@` imports.

**The rules block stays under 100 lines**, and the selftest checks it. A rule the agent keeps missing becomes a hook, not emphasis (ADR-0001).

## kit.edn

```clojure
{:repo      "shundeev/site"
 :showcase  "Site"
 :modules   #{}          ; #{:clojure} for the shared zprint/clj-kondo setup
 :user-test {:run "npm ci && npx playwright test" :artifacts "test-results"}} ; optional, run in CI
```

Defaults come from `kit-defaults.edn`: the board, the base branch, the code owners and the agent's account. A project can override `:board`, `:base`, `:owners`, `:agent` and `:claude-settings`; the last is merged into the generated settings.

## Developing dev-kit

```sh
test/selftest.sh     # a throwaway project: init/doctor/repairs, hooks, kit start/finish/merge, kit retro
test/e2e.sh --clean  # removes what an interrupted end-to-end run left in the sandbox; runs younger than 30 minutes stay
```

The decisions are in `adr/`. The delivery flow, the guard hook and the subagents were first built in bash for [Sprecha](https://github.com/the-kind-robots/learning-app).

## License

MIT
