---
name: pr-fix
description: AI-native workflow — read GitHub PR review comments, fix the code with the coder subagent, push, reply to reviewers, and save reusable lessons to memory so future /task runs avoid the same mistakes.
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
4. Keep only feedback that is still open:
   - unresolved review threads whose **last** comment does not contain `<!-- ai-native -->`
   - review summaries (`CHANGES_REQUESTED` or `COMMENTED` with a non-empty body) and general PR comments that have no later reply containing the marker
   - skip bots (CI, coverage) unless they report a real failure
   If nothing is left, say so and stop.
5. Find the brief: take `<!-- ai-native:brief=<ID> -->` from the PR body, or match the branch name. Read it. Read both lesson files.

## Phase 2 — Triage
Classify each item:
- **fix**: a clear change request
- **question**: the reviewer asks something; answer it, and change code only if the answer shows a problem
- **discuss**: you think the request is wrong or out of scope

Show a short table (item, file:line, class, planned action). If any item is **discuss**, or a request conflicts with the brief, use AskUserQuestion before changing code.

## Phase 3 — Fix
1. Spawn `ai-native-coder` with: the brief, the relevant lessons, and every **fix** item with its file, line, and the reviewer's exact words. Tell it to make only those changes.
2. Spawn `ai-native-reviewer` on the new changes (`git diff`) to confirm each item is addressed and nothing regressed. Allow at most 1 extra fix round.
3. Run the brief's test, lint, and type commands yourself and confirm they pass.
4. Commit: `fix(<KEY or ID>): address review feedback on #<N>`. Then `git push`.

## Phase 4 — Reply to reviewers
- Inline thread: `gh api repos/{owner}/{repo}/pulls/<N>/comments/<databaseId of first comment>/replies -f body='<reply>'`
- General feedback: `gh pr comment <N> --body '<reply>'`
- Keep replies to 1-3 sentences: what changed (with the short commit SHA), or the answer to the question. End each reply with `<!-- ai-native -->`.
- Do not resolve threads. The reviewer resolves them.

## Phase 5 — MEMORY (the important part)
For each piece of feedback, ask: *would knowing this up front have avoided the comment?* If yes, write a lesson.

1. **Generalize.** Write a rule for future tasks, not a note about this diff.
   - Bad: "rename `x` to `count` in report.ts"
   - Good: "Use descriptive variable names; reviewers reject single-letter names outside loops"
2. **Pick the file.** Use `repos/REPO_SLUG.md` for anything specific to this codebase, its conventions, or its stack (most lessons). Use `global.md` only for rules that apply to any project (for example, "every new endpoint needs a test").
3. **Format.** One line per lesson, under a `## <Category>` heading (Testing, Naming, Architecture, Error handling, API, Style, Process…):
   `- [YYYY-MM-DD] <rule> — why: <reviewer's reason> (PR #<N>, seen 1x)`
4. **Dedupe.** If a similar lesson already exists, update its date and increase `seen Nx` instead of adding a new line. Rules seen 3 or more times are critical: move them to the top section `## Always`.
5. **Compact.** If a file has more than ~60 lessons, merge overlapping ones and drop any that the codebase now enforces (for example, through lint rules).
6. Create files and directories if missing. A new repo file starts with `# Lessons — <owner/repo>`.
7. Append a `## Review round <k>` section to the brief: the comments, what changed, and the lessons added.

## Report
Tell the user: how many items were fixed, answered, or left for discussion; the pushed commit; and the exact lessons added or updated, with file paths.
