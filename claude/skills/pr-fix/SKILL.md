---
name: pr-fix
description: AI-native workflow — read GitHub PR review comments and failing CI checks, fix the code with the coder subagent, push, reply to reviewers, and save reusable lessons to memory so future /task runs avoid the same mistakes.
argument-hint: "[PR number — defaults to the current branch's PR]"
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
---

# /pr-fix — Review comments → Fix → Memory

Input: `$ARGUMENTS`

Paths match `/task`:
- `AI_HOME` = `~/.claude/ai-native`
- `REPO_SLUG` = `owner-repo` from `gh repo view --json nameWithOwner -q .nameWithOwner` (`/` → `-`)
- Lessons: `AI_HOME/memory/global.md` and `AI_HOME/memory/repos/REPO_SLUG.md`
- Briefs: `AI_HOME/briefs/REPO_SLUG/`

Every comment you post ends with the marker `<!-- ai-native -->`. Later runs use it to skip feedback that has already been handled.

## Phase 1 — Collect feedback
1. Find the PR number: `$ARGUMENTS` if given, otherwise `gh pr view --json number -q .number`. If there is no PR, stop.
   Check `gh pr view <N> --json state -q .state`. If it is `MERGED` or `CLOSED`, say "PR #N is <state>; nothing to fix. You can stop the loop (Esc)." and stop.
2. `git status --porcelain` must be empty. If it is not, ask the user before continuing. Then `gh pr checkout <N>` and `git pull --ff-only`.
3. Fetch the feedback:
   - PR metadata, reviews, and general comments: `gh pr view <N> --json number,title,url,body,headRefName,baseRefName,author,reviews,comments`
   - Review threads with resolution state:
     ```
     gh api graphql -F owner='{owner}' -F repo='{repo}' -F n=<N> -f query='
       query($owner:String!,$repo:String!,$n:Int!){ repository(owner:$owner,name:$repo){ pullRequest(number:$n){
         reviewThreads(first:100){ nodes{ id isResolved isOutdated path line
           comments(first:50){ nodes{ databaseId author{login} body url } } } } } } }'
     ```
   - CI checks for the PR's latest commit: `gh pr checks <N> --json name,state,bucket,link,workflow`. This exits non-zero when checks fail, so read the JSON and ignore the exit code.
     For each check with `bucket` = `fail`: if `link` is a GitHub Actions URL (`…/actions/runs/<run-id>/job/<job-id>`), get the log with `gh run view <run-id> --log-failed | tail -n 200`. Otherwise use the check's name, description, and link.
4. Keep only feedback that is still open:
   - unresolved review threads whose **last** comment does not contain `<!-- ai-native -->`
   - review summaries (`CHANGES_REQUESTED` or `COMMENTED` with a non-empty body) and general PR comments that have no later reply containing the marker
   - failing CI checks (`bucket` = `fail`). Each is one item. Its state comes from GitHub, so it needs no marker.
   - skip bot comments (coverage, CI summaries); failing checks already cover them
   If there are no open items: if any check has `bucket` = `pending`, say "CI is still running on #N; will check again next run" and stop. Otherwise say nothing is left and stop.
   **Loop guard:** if a CI check fails for the same reason it failed before the last `fix(…)` commit from ai-native, do not try a third time. Report it to the user with the log excerpt and stop.
5. Find the brief: take `<!-- ai-native:brief=<ID> -->` from the PR body, or match the branch name. Read it. Read both lesson files.

## Phase 2 — Triage
Classify each item:
- **fix**: a clear change request
- **question**: the reviewer asks something; answer it, and change code only if the answer shows a problem
- **discuss**: you think the request is wrong or out of scope
- **ci**: a failing check. First reproduce it locally with the matching command from `.ai-native.json` `check` (or the step that failed in the log).
  - If it fails locally too, it is a normal fix.
  - If it passes locally, the difference is in the environment: an uncommitted lock file, a dependency missing from the manifest, a Python or Node version mismatch, a missing env var or secret, or a test that depends on local files or network. Find out which before changing code. If the fix needs a repo secret or a settings change, ask the user. You cannot change those.

Show a short table (item, file:line, class, planned action). If any item is **discuss**, or a request conflicts with the brief, use AskUserQuestion before changing code.

## Phase 3 — Fix
1. Spawn `ai-native-coder` with: the brief, the relevant lessons, and every **fix** and **ci** item. For review items, include the file, line, and the reviewer's exact words. For CI items, include the check name, the failing command, the log excerpt, and your diagnosis. Tell it to make only those changes.
2. Spawn `ai-native-reviewer` on the new changes (`git diff`) to confirm each item is addressed and nothing regressed. Allow at most 1 extra fix round.
3. Run every command in `.ai-native.json` `check` (or the brief's test, lint, and type commands) yourself and confirm they pass.
4. Commit: `fix(<KEY or ID>): address review feedback on #<N>`, or `fix(<KEY or ID>): fix CI on #<N>` when only CI items were fixed. Then `git push`.
   If an ai-native hook blocks the commit or push, fix the cause and retry. Never bypass a hook: no `--no-verify`, and no weakening `.ai-native.json` or lint, type, or test config.

## Phase 4 — Reply to reviewers
- Inline thread: `gh api repos/{owner}/{repo}/pulls/<N>/comments/<databaseId of first comment>/replies -f body='<reply>'`
- General feedback: `gh pr comment <N> --body '<reply>'`
- Keep replies to 1-3 sentences: what changed (with the short commit SHA), or the answer to the question. End each reply with `<!-- ai-native -->`.
- Do not resolve threads. The reviewer resolves them.
- CI items get no reply. The new check run on the pushed commit is the answer.

## Phase 5 — MEMORY (the important part)
For each piece of feedback, ask: *would knowing this up front have avoided the comment?* If yes, write a lesson.

1. **Generalize.** Write a rule for future tasks, not a note about this diff.
   - Bad: "rename `x` to `count` in report.ts"
   - Good: "Use descriptive variable names; reviewers reject single-letter names outside loops"
   - **CI failures:** write a lesson only when the hooks could not have caught it, for example "Commit uv.lock whenever dependencies change — why: CI runs `uv sync --locked`". Skip failures that the local `check` commands already catch.
2. **Pick the file.** Use `repos/REPO_SLUG.md` for anything specific to this codebase, its conventions, or its stack (most lessons). Use `global.md` only for rules that apply to any project (for example, "every new endpoint needs a test").
3. **Format.** One line per lesson, under a `## <Category>` heading (Testing, Naming, Architecture, Error handling, API, Style, Process…):
   `- [YYYY-MM-DD] <rule> — why: <reviewer's reason> (PR #<N>, seen 1x)`
4. **Dedupe.** If a similar lesson already exists, update its date and increase `seen Nx` instead of adding a new line. Rules seen 3 or more times are critical: move them to the top section `## Always`.
5. **Compact.** If a file has more than ~60 lessons, merge overlapping ones and drop any that the codebase now enforces (for example, through lint rules).
6. Create files and directories if missing. A new repo file starts with `# Lessons — <owner/repo>`.
7. Append a `## Review round <k>` section to the brief: the comments, what changed, and the lessons added.

## Report
Tell the user: how many review items were fixed, answered, or left for discussion; which CI checks were fixed; the pushed commit; and the exact lessons added or updated, with file paths.
