# ai-native

An AI-native development workflow for [Claude Code](https://claude.com/claude-code): **Brief → Agents → Review → Memory**.

```
/task PROJ-123  or  /task "add CSV export to reports"
  BRIEF   reads the Jira ticket + past lessons + the code → writes a brief → you approve it
  AGENTS  creates a branch → the ai-native-coder subagent implements and tests
  REVIEW  the ai-native-reviewer subagent checks the diff against the brief and lessons → fixes → opens a GitHub PR
/pr-fix 42
  FIX     reads the reviewers' comments → coder fixes → pushes → replies on the PR
  MEMORY  turns each comment into a reusable lesson → the next /task starts smarter
```

## Install

Requirements: [Claude Code](https://docs.claude.com/en/docs/claude-code), the [GitHub CLI](https://cli.github.com) (`gh auth login`), and Jira Cloud (optional).

```bash
curl -fsSL https://raw.githubusercontent.com/hoangtrankim/ai-native/main/install.sh | bash
```

To install from a fork, set `AI_NATIVE_REPO=owner/repo` before `bash`.

What the installer does:
- copies the `/task` and `/pr-fix` skills and the two subagents into `~/.claude/`, so they work in every project
- creates the memory folder `~/.claude/ai-native/memory/` and never overwrites lessons that already exist
- registers the Atlassian Rovo MCP server (Jira) at user scope. After installing, run `/mcp` in Claude Code and sign in once.

Options (put them after `bash -s --`):

| Flag | Effect |
|---|---|
| `--project` | Install into the current repo's `./.claude/` so you can commit it for your team |
| `--ref v1.0` | Install a specific tag or branch |
| `--skip-mcp` | Skip the Jira MCP setup |
| `--uninstall` | Remove the skills and agents (memory is kept) |

You can also install from a local clone with `./install.sh`. Re-run the same command to update.

## Usage

| Command | What happens |
|---|---|
| `/task PROJ-123` | Fetches the Jira ticket, writes a brief, asks for your approval, implements, self-reviews, opens the PR, and comments the PR link on the ticket |
| `/task "fix the date bug in invoices"` | Same flow, starting from a free-text description |
| `/pr-fix` or `/pr-fix 42` | Handles the open review comments on the PR, replies to reviewers, and saves lessons |

You approve the brief before any code is written. Everything after that runs on its own until the PR is open.

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
└── memory/global.md              # starter template
```