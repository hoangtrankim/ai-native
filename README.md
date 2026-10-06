# ai-native

An AI-native development workflow for [Claude Code](https://claude.com/claude-code): **Brief → Agents → Review → Memory**.

```
/task PROJ-123  or  /task "add CSV export to reports"
  BRIEF   reads the Jira ticket + past lessons + the code → writes a brief → you approve it
  AGENTS  creates a branch → the ai-native-coder subagent implements and tests
  REVIEW  the ai-native-reviewer subagent checks the diff against the brief and lessons → fixes → opens a GitHub PR
/pr-fix 42
  FIX     reads review comments + failing CI → coder fixes → pushes → replies on the PR
  MEMORY  turns each comment into a reusable lesson → the next /task starts smarter
HOOKS     lint every edit · block commit/push/PR until all checks pass · CI runs the same checks
```

## Install

Requirements: [Claude Code](https://docs.claude.com/en/docs/claude-code), the [GitHub CLI](https://cli.github.com) (`gh auth login`), `jq` (needed by the hooks; included in macOS 15+, otherwise `brew install jq`), and Jira Cloud (optional).

```bash
curl -fsSL https://raw.githubusercontent.com/hoangtrankim/ai-native/main/install.sh | bash
```

To install from a fork, set `AI_NATIVE_REPO=owner/repo` before `bash`.

What the installer does:
- copies the `/task` and `/pr-fix` skills and the two subagents into `~/.claude/`, so they work in every project
- creates the memory folder `~/.claude/ai-native/memory/` and never overwrites lessons that already exist
- adds two lint/test hooks to `~/.claude/settings.json`. Your other hooks and settings are kept, and a backup is saved as `settings.json.bak.ai-native`. The hooks do nothing in repos without `.ai-native.json`.
- registers the Atlassian Rovo MCP server (Jira) at user scope. After installing, run `/mcp` in Claude Code and sign in once.

Options (put them after `bash -s --`):

| Flag | Effect |
|---|---|
| `--project-setup` | Run inside a repo to add `.ai-native.json` and a CI workflow to it (see [Hooks and CI](#hooks-and-ci)) |
| `--project` | Install into the current repo's `./.claude/` so you can commit it for your team |
| `--ref v1.0` | Install a specific tag or branch |
| `--skip-mcp` | Skip the Jira MCP setup |
| `--no-hooks` | Don't add the lint/test hooks |
| `--uninstall` | Remove the skills, agents, and hooks (memory is kept) |

You can also install from a local clone with `./install.sh`. Re-run the same command to update.

## Usage

| Command | What happens |
|---|---|
| `/task PROJ-123` | Fetches the Jira ticket, writes a brief, asks for your approval, implements, self-reviews, opens the PR, and comments the PR link on the ticket |
| `/task "fix the date bug in invoices"` | Same flow, starting from a free-text description |
| `/pr-fix` or `/pr-fix 42` | Handles the open review comments and failing CI checks on the PR, replies to reviewers, and saves lessons |

You approve the brief before any code is written. Everything after that runs on its own until the PR is open.

Before writing the brief, `/task` switches to the default branch and pulls it, so the brief always describes the latest code. It also deletes local branches whose PRs were merged. If you have open PRs, it asks whether the new task depends on one: you can continue from `main`, stop and merge first, or stack the new branch on that PR.

### Auto-fix while you review on GitHub

Use Claude Code's built-in `/loop` command to have Claude check the PR on a timer. Start it in the repo, right after `/task` opens the PR:

```
/loop 10m /pr-fix 42
```

Every 10 minutes Claude runs `/pr-fix 42`:
- **New comments:** fixes the code, runs the tests, pushes to the PR branch, replies to each comment, and saves lessons.
- **Failing CI:** reads the failed job log, reproduces the failure locally, fixes it, and pushes. If CI fails for the same reason twice, it stops and asks you.
- **CI still running:** waits for the next check.
- **Nothing new:** reports that nothing is left and waits for the next check.
- **PR merged or closed:** says so; press `Esc` to stop the loop.

Each reply Claude posts carries a hidden `<!-- ai-native -->` marker, so a comment that is already handled is never fixed twice. Leave out `10m` to let Claude choose how often to check. Press `Esc` or close the session to stop.

Typical flow:
1. `/task PROJ-123` opens PR #42.
2. `/loop 10m /pr-fix 42`, then leave the terminal open.
3. Review on GitHub and leave comments.
4. Within about 10 minutes, the fixes are pushed and your comments have replies.
5. Approve and merge. The lessons are already saved, so the next `/task` uses them.

Tips:
- The loop only runs while this Claude Code session is open and your computer is awake.
- Submit your comments as one GitHub review ("Start a review" → "Submit review"), not one at a time, so each check fixes everything together.
- To fix only some comments, end your review with a summary comment that says which ones to fix. Claude reads the whole review before it starts.
- A check pauses and asks you in the terminal when the working tree has uncommitted changes, or when Claude disagrees with a comment. Answer there and the loop continues.
- Run the loop in its own terminal or worktree. It checks out the PR branch, so it can conflict with other work in the same folder.

## Hooks and CI

Instructions alone can't guarantee an agent runs lint and tests. Hooks can, because Claude Code runs them itself. Set them up once per repo:

```bash
cd your-repo
curl -fsSL https://raw.githubusercontent.com/hoangtrankim/ai-native/main/install.sh | bash -s -- --project-setup
```

This detects the stack (Python + uv, Node, or a generic template you fill in) and creates two files. Commit both through a PR.

**`.ai-native.json`** is the single source of truth for the repo's checks:

```json
{
  "extensions": [".py"],
  "format": "uv run ruff format",
  "lint": "uv run ruff check --fix",
  "check": ["uv run ruff check .", "uv run ruff format --check .", "uv run pytest -q"]
}
```

| Layer | When | What happens |
|---|---|---|
| **Edit hook** (`PostToolUse`) | Every time Claude edits a file matching `extensions` | Runs `format` then `lint` on that file. Remaining lint errors go straight back to Claude to fix. |
| **Ship hook** (`PreToolUse`) | Before `git commit`, `git push`, or `gh pr create` | Runs every `check` command. If one fails, the command is blocked and Claude must fix it. Commits and pushes to `main` are always blocked. If the files haven't changed since the last passing run, the checks are skipped. |
| **CI** (`.github/workflows/ai-native-ci.yml`) | Every PR and every push to `main` | Runs the same `check` commands on GitHub. `/pr-fix` reads failures and fixes them. |

For a true merge gate, turn on **Settings → Branches → Require status checks → `checks`** in GitHub.

The hooks only affect Claude. You can still commit by hand. To turn them off for one repo, delete `.ai-native.json`. To remove them everywhere, run `--uninstall` or re-run the installer with `--no-hooks`.

## Memory

```
~/.claude/ai-native/
├── memory/
│   ├── global.md              # rules that apply to every project
│   └── repos/<owner-repo>.md  # rules for one codebase (most lessons)
└── briefs/<owner-repo>/<ID>.md  # each task's brief and its review history
```

Each lesson is one line: `- [2026-10-05] Wrap DB calls in the repo's withTx() helper — why: reviewer flagged partial writes (PR #42, seen 2x)`.
A lesson seen 3 or more times moves to the `## Always` section. These files are plain markdown, so you can edit, delete, or add lessons by hand. To share one repo's lessons with your team, copy them into that repo's `CLAUDE.md`.

## Repository layout

```
install.sh
claude/
├── skills/task/SKILL.md          # /task orchestrator
├── skills/pr-fix/SKILL.md        # /pr-fix orchestrator + memory writer
├── agents/ai-native-coder.md     # implementation subagent (never commits)
├── agents/ai-native-reviewer.md  # read-only reviewer subagent (opus)
├── hooks/check.sh                # edit + ship hooks, driven by .ai-native.json
└── memory/global.md              # starter template
templates/<python-uv|node|generic>/
├── ai-native.json                # becomes <repo>/.ai-native.json
└── ci.yml                        # becomes <repo>/.github/workflows/ai-native-ci.yml
```