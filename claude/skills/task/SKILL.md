---
name: task
description: AI-native workflow — turn a Jira ticket ID or a task description into a brief, implement it with a coder subagent, self-review it, and open a GitHub pull request.
argument-hint: <JIRA-KEY | "task description">
disable-model-invocation: true
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Agent
  - AskUserQuestion
  - Bash(git:*)
  - Bash(gh:*)
  - Bash(mkdir:*)
  - Bash(date:*)
  - mcp__atlassian
---

# /task — Brief → Agents → Review → PR

Input: `$ARGUMENTS`

Paths used below:
- `AI_HOME` = `~/.claude/ai-native`
- `REPO_SLUG` = `owner-repo` from `gh repo view --json nameWithOwner -q .nameWithOwner` (replace `/` with `-`); if that fails, the basename of `git rev-parse --show-toplevel`
- Lessons: `AI_HOME/memory/global.md` and `AI_HOME/memory/repos/REPO_SLUG.md`
- Briefs: `AI_HOME/briefs/REPO_SLUG/<ID>.md`

Work through the phases in order. Stop and tell the user if any step fails; never guess past a failure.

## Phase 0 — Preflight
1. Confirm you are inside a git repo (`git rev-parse --show-toplevel`). If not, stop.
2. `git status --porcelain` must be empty. If it is not, ask the user whether to stop or continue on top of the existing changes.
3. `gh auth status` must succeed. If it fails, tell the user to run `! gh auth login` and stop.
4. Find the default branch: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
5. **Start from the latest default branch.** The brief must describe the code as it is now, so do this before Phase 1. This folder may be one of several git worktrees running jobs in parallel, and git refuses to check out a branch that another worktree already has. So never run `git switch <default>`. Work from the remote ref instead:
   `git fetch --prune origin && git switch --detach origin/<default>`
   If `<default>` is not checked out in any worktree (`git worktree list`), also fast-forward the local copy with `git fetch origin <default>:<default>`. Ignore a failure there.
6. **Clean up merged branches.** Collect the branches checked out in any worktree (`git worktree list --porcelain`, the `branch refs/heads/…` lines) and never touch those. For every other local branch except `<default>`, run `gh pr list --state merged --head <branch> --json number -q length`. If the result is greater than 0, delete the branch with `git branch -D <branch>`. List the deleted branches in one line. If a worktree's branch has a merged PR, mention that its folder can be removed with `new-job --clean` (at `.claude/bin/new-job` for a project install, or `~/.claude/ai-native/bin/new-job` for a global install).
7. **Check open PRs.** Run `gh pr list --author @me --state open --json number,title,headRefName`. If any are open, show them and ask with AskUserQuestion whether this task depends on one of them. Options:
   - **Independent:** continue from `origin/<default>` (the usual case, and the right choice for parallel jobs).
   - **Stop:** the user merges first, then re-runs `/task`.
   - **Stack on #N:** `git switch --detach origin/<its headRefName>`. That branch becomes `BASE` for the rest of this task.

   `BASE` = `<default>` unless the user chose to stack. You are now on a detached HEAD at the latest `origin/<BASE>`.
8. Read `.ai-native.json` in the repo root if it exists. Its `check` list is this repo's official lint and test commands. The ai-native hooks run them automatically: the file you edit is formatted and linted on every edit, and every command in `check` must pass before `git commit`, `git push`, or `gh pr create` is allowed.

## Phase 1 — BRIEF
1. **Identify the task.**
   - If `$ARGUMENTS` matches `^[A-Z][A-Z0-9]+-[0-9]+$`, it is a Jira key. Fetch the issue with the Atlassian MCP tools (find the cloud ID with the accessible-resources tool if needed, then get the issue). Collect summary, description, acceptance criteria, issue type, priority, linked issues and comments. `ID` = the key.
     If the Atlassian tools are missing or unauthenticated, tell the user to run `/mcp` and sign in to `atlassian`, or paste the ticket text, and stop.
   - Otherwise treat `$ARGUMENTS` as a free-text description. `ID` = `task-<YYYYMMDD>-<short-slug>`.
   - If `$ARGUMENTS` is empty, ask the user for a ticket or description.
2. **Load memory.** Read `global.md` and the repo lessons file (either may not exist yet). Also read the repo's `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md` if present. Pick out the lessons relevant to this task.
3. **Explore the code.** Find the files, patterns, and existing utilities the change touches, and work out how this repo runs tests, lint, and type checks. Use the `.ai-native.json` `check` list if present; otherwise check package.json scripts, Makefile, pyproject, and CI config. For a broad search, use an Explore subagent.
4. **Write the brief** to `AI_HOME/briefs/REPO_SLUG/<ID>.md` (create directories with `mkdir -p`):

   ```markdown
   # <ID>: <title>
   Source: <Jira URL or "description">   Branch: feat/<ID>-<slug>   Status: draft
   ## Goal
   <1-3 sentences: the outcome, not the steps>
   ## Context
   <what exists today, relevant files with paths, related tickets>
   ## Scope
   In: ...
   Out: ...
   ## Acceptance criteria
   - [ ] ...
   ## Implementation plan
   1. <file> — <change>
   ## Test plan
   <tests to add or update; exact commands to run tests, lint, types>
   ## Lessons that apply
   - <copied verbatim from memory, or "none yet">
   ## Open questions
   - <anything ambiguous>
   ```
5. **Get approval.** Show the brief and use AskUserQuestion with these options: Approve / Edit (user says what to change) / Cancel. Resolve every open question before you approve. Do not write code before approval. Set `Status: approved` in the file.

## Phase 2 — AGENTS
1. You are already on the latest `origin/<BASE>` (Phase 0). Create the branch from there: `git switch -c feat/<ID>-<slug>` (slug: lowercase, hyphens, at most 40 characters).
2. Spawn the `ai-native-coder` subagent. Subagents start with no context, so paste the **full brief text** and the **full list of relevant lessons** into the prompt, along with the repo root and the test commands. Do not refer it to files it cannot see without saying where they are.
3. Read its report: files changed, tests run, deviations, and open questions. If it raises a blocking question, ask the user and spawn the coder again with the answer.

## Phase 3 — REVIEW
1. Spawn the `ai-native-reviewer` subagent. Give it the brief, the lessons, the `BASE` branch name, and tell it to review `git diff <BASE>...HEAD` plus uncommitted changes (`git diff`, `git status`).
2. If it reports any **blocking** findings, send them to `ai-native-coder` to fix, then review again. Allow at most 2 fix rounds. Then report any blocking findings still open to the user and ask how to proceed.
3. Run the brief's test, lint, and type commands yourself and confirm they pass. Never claim they pass unless you saw them pass.

**Hooks.** An ai-native hook may block `git commit`, `git push`, or `gh pr create` with a message that starts with `ai-native:`. When that happens, read the output and fix the cause; for anything non-trivial, send it to `ai-native-coder`. Then retry. Never get around a hook: do not use `--no-verify`, edit `.ai-native.json`, or loosen lint, type, or test config to make checks pass. If you are blocked for being on `<default>`, create the feature branch.

## Phase 4 — PULL REQUEST
1. Commit with `git add -A` and a Conventional Commit message that starts with the Jira key if there is one, e.g. `feat(PROJ-123): add CSV export to reports`. Use several commits only if the work splits into logical pieces.
2. `git push -u origin HEAD`.
3. `gh pr create --base <BASE> --title "<KEY>: <summary>" --body-file <tmpfile>`. The body contains:
   - Summary (2-4 bullets) and a Jira link if there is one
   - The acceptance criteria as a checklist, ticked where verified
   - Test evidence: commands run and their results
   - Any reviewer nits left unaddressed
   - Last line: `<!-- ai-native:brief=<ID> -->`
4. If the task came from Jira, add a comment to the issue with the PR link using the Atlassian MCP tools.
5. Update the brief file: `Status: pr-open`, add `PR: <url>`.
6. Report to the user: the PR URL, a one-line summary, and a reminder to run `/loop 10m /pr-fix <number>`. That command picks up both review comments and failing CI checks.
