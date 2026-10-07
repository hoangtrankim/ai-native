#!/usr/bin/env bash
# ai-native installer — adds /task, /pr-fix, the ai-native subagents, and lint/test hooks to Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/hoangtrankim/ai-native/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --project-setup  # inside a repo: add .ai-native.json + CI
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Options:
#   --project        install skills/agents/hooks into ./.claude instead of ~/.claude
#   --project-setup  set up the current repo only: .ai-native.json + .github/workflows/ai-native-ci.yml
#   --ref <ref>      branch or tag to install (default: main)
#   --skip-mcp       don't register the Atlassian (Jira) MCP server
#   --no-hooks       don't add the lint/test hooks to settings.json
#   --uninstall      remove skills, agents, and hooks (memory and briefs are kept)
# Env:
#   AI_NATIVE_REPO   GitHub "owner/repo" to download from (default below)
set -euo pipefail

REPO="${AI_NATIVE_REPO:-hoangtrankim/ai-native}"
REF="main"
TARGET="$HOME/.claude"
SKIP_MCP=0
NO_HOOKS=0
UNINSTALL=0
PROJECT_SETUP=0
AI_HOME="$HOME/.claude/ai-native"            # memory, briefs, and hook script are always global
ATLASSIAN_MCP_URL="https://mcp.atlassian.com/v1/mcp/authv2"
SKILLS=(task pr-fix)
AGENTS=(ai-native-coder ai-native-reviewer)
MARKER=".ai-native"
PROJECT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)       PROJECT=1 ;;
    --project-setup) PROJECT_SETUP=1 ;;
    --ref)           REF="${2:?--ref needs a value}"; shift ;;
    --skip-mcp)      SKIP_MCP=1 ;;
    --no-hooks)      NO_HOOKS=1 ;;
    --uninstall)     UNINSTALL=1 ;;
    -h|--help)       sed -n '2,17p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

# Where the hook script lives and how settings.json refers to it (variables expand when the hook runs).
# Global: ~/.claude/ai-native/hooks/check.sh. Project: <repo>/.claude/hooks/ai-native-check.sh,
# committed with the repo so the project install doesn't depend on anything in ~/.claude.
if [[ $PROJECT -eq 1 ]]; then
  TARGET="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude"
  HOOK_FILE="$TARGET/hooks/ai-native-check.sh"
  HOOK_REF='"$CLAUDE_PROJECT_DIR"/.claude/hooks/ai-native-check.sh'
  BIN_DIR="$TARGET/bin"
else
  HOOK_FILE="$AI_HOME/hooks/check.sh"
  HOOK_REF='"$HOME/.claude/ai-native/hooks/check.sh"'
  BIN_DIR="$AI_HOME/bin"
fi
HOOK_POST="$HOOK_REF post-edit"
HOOK_PRE="$HOOK_REF pre-ship"

# Add (add=1) or remove (add=0) the ai-native hook entries in a settings.json, keeping every other hook.
update_settings_hooks() {
  local settings="$1" add="$2" tmpf
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found; could not update hooks in $settings. Install jq (brew install jq) and re-run."
    return 0
  fi
  mkdir -p "$(dirname "$settings")"
  if [[ -s "$settings" ]]; then
    [[ $PROJECT -eq 1 ]] || cp "$settings" "$settings.bak.ai-native"   # a repo has git history instead
  else
    echo '{}' >"$settings"
  fi
  tmpf="$(mktemp)"
  jq --arg post "$HOOK_POST" --arg pre "$HOOK_PRE" --argjson add "$add" '
    def strip: map(select([.hooks[]?.command // "" | tostring | test("ai-native/hooks/check\\.sh|ai-native-check\\.sh")] | any | not));
    .hooks = (.hooks // {})
    | .hooks.PostToolUse = ((.hooks.PostToolUse // []) | strip)
    | .hooks.PreToolUse  = ((.hooks.PreToolUse  // []) | strip)
    | if $add == 1 then
        .hooks.PostToolUse += [{matcher: "Edit|Write|MultiEdit", hooks: [{type: "command", command: $post, timeout: 120}]}]
        | .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $pre, timeout: 900}]}]
      else . end
    | if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end
    | if (.hooks.PreToolUse  | length) == 0 then del(.hooks.PreToolUse)  else . end
  ' "$settings" >"$tmpf" && mv "$tmpf" "$settings"
}

if [[ $UNINSTALL -eq 1 ]]; then
  for s in "${SKILLS[@]}"; do
    [[ -f "$TARGET/skills/$s/$MARKER" ]] && rm -rf "$TARGET/skills/$s" && info "Removed skill /$s"
  done
  for a in "${AGENTS[@]}"; do
    rm -f "$TARGET/agents/$a.md" && info "Removed agent $a"
  done
  if [[ -f "$TARGET/settings.json" ]]; then
    update_settings_hooks "$TARGET/settings.json" 0 && info "Removed ai-native hooks from $TARGET/settings.json"
  fi
  rm -f "$HOOK_FILE" "$BIN_DIR/new-job"
  [[ $PROJECT -eq 1 ]] || rm -rf "$AI_HOME/hooks" "$AI_HOME/bin"
  info "Kept memory and briefs in $AI_HOME (delete manually if unwanted)."
  exit 0
fi

# --- Locate source files: local checkout, or download a tarball from GitHub ---
SRC=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -d "$here/claude/skills" ]] && SRC="$here/claude"
fi
if [[ -z "$SRC" ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  info "Downloading $REPO@$REF"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$tmp"
  SRC="$(find "$tmp" -mindepth 2 -maxdepth 2 -type d -name claude | head -n1)"
  [[ -d "$SRC/skills" ]] || { echo "Download did not contain claude/skills" >&2; exit 1; }
fi
TEMPLATES="$(dirname "$SRC")/templates"

# --- Project setup mode: add .ai-native.json + CI to the current repo, then stop ---
if [[ $PROJECT_SETUP -eq 1 ]]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "--project-setup must run inside a git repo" >&2; exit 1; }
  if   [[ -f "$root/pyproject.toml" && -f "$root/uv.lock" ]]; then stack="python-uv"
  elif [[ -f "$root/package.json" ]]; then stack="node"
  else stack="generic"
  fi
  info "Detected stack: $stack"
  if [[ -f "$root/.ai-native.json" ]]; then
    info "Kept existing .ai-native.json"
  else
    cp "$TEMPLATES/$stack/ai-native.json" "$root/.ai-native.json"
    info "Created .ai-native.json"
  fi
  wf="$root/.github/workflows/ai-native-ci.yml"
  if [[ -f "$wf" ]]; then
    info "Kept existing .github/workflows/ai-native-ci.yml"
  else
    mkdir -p "$(dirname "$wf")"
    cp "$TEMPLATES/$stack/ci.yml" "$wf"
    info "Created .github/workflows/ai-native-ci.yml"
  fi
  [[ "$stack" == "generic" ]] && warn "Edit .ai-native.json and the CI workflow with your real lint/test commands."
  cat <<EOF

Project set up. Next:
  1. Review .ai-native.json — "check" runs before every commit/push/PR and in CI.
  2. Commit both files on a branch and open a PR (the hooks block commits to the default branch).
  3. Optional: GitHub → Settings → Branches → require the "checks" status before merging.
EOF
  exit 0
fi

# --- Install skills (back up any same-named skill we don't own) ---
mkdir -p "$TARGET/skills" "$TARGET/agents"
for s in "${SKILLS[@]}"; do
  dest="$TARGET/skills/$s"
  if [[ -d "$dest" && ! -f "$dest/$MARKER" ]]; then
    bak="$dest.bak.$(date +%Y%m%d%H%M%S)"
    warn "Existing skill /$s backed up to $bak"
    mv "$dest" "$bak"
  fi
  rm -rf "$dest"; cp -R "$SRC/skills/$s" "$dest"; touch "$dest/$MARKER"
  info "Installed skill /$s -> $dest"
done

for a in "${AGENTS[@]}"; do
  cp "$SRC/agents/$a.md" "$TARGET/agents/$a.md"
  info "Installed agent $a"
done

# --- Parallel-jobs helper ---
mkdir -p "$BIN_DIR"
cp "$SRC/bin/new-job" "$BIN_DIR/new-job"
chmod +x "$BIN_DIR/new-job"
info "Installed parallel-jobs helper -> $BIN_DIR/new-job"

# --- Hooks: script lives in AI_HOME; entries are merged into settings.json ---
if [[ $NO_HOOKS -eq 0 ]]; then
  mkdir -p "$(dirname "$HOOK_FILE")"
  cp "$SRC/hooks/check.sh" "$HOOK_FILE"
  chmod +x "$HOOK_FILE"
  update_settings_hooks "$TARGET/settings.json" 1
  info "Installed lint/test hooks (active only in repos with .ai-native.json)"
fi

# --- Memory: create once, never overwrite learned lessons ---
mkdir -p "$AI_HOME/memory/repos" "$AI_HOME/briefs"
if [[ ! -f "$AI_HOME/memory/global.md" ]]; then
  cp "$SRC/memory/global.md" "$AI_HOME/memory/global.md"
  info "Created $AI_HOME/memory/global.md"
else
  info "Kept existing memory in $AI_HOME/memory"
fi

# --- Dependencies ---
if ! command -v gh >/dev/null 2>&1; then
  warn "GitHub CLI 'gh' not found. Install it (macOS: brew install gh) and run: gh auth login"
elif ! gh auth status >/dev/null 2>&1; then
  warn "gh is not logged in. Run: gh auth login"
fi
command -v jq >/dev/null 2>&1 || warn "jq not found; the hooks need it (brew install jq)."

if [[ $SKIP_MCP -eq 0 ]]; then
  if command -v claude >/dev/null 2>&1; then
    if claude mcp get atlassian >/dev/null 2>&1; then
      info "Atlassian MCP server already configured"
    else
      claude mcp add --scope user --transport http atlassian "$ATLASSIAN_MCP_URL" \
        && info "Added Atlassian MCP server (run /mcp in Claude Code to sign in)" \
        || warn "Could not add Atlassian MCP. Run: claude mcp add --scope user --transport http atlassian $ATLASSIAN_MCP_URL"
    fi
  else
    warn "'claude' CLI not found; skipped Jira setup. Later run: claude mcp add --scope user --transport http atlassian $ATLASSIAN_MCP_URL"
  fi
fi

cat <<EOF

ai-native installed.
  1. Restart Claude Code (or start a new session).
  2. Jira: run /mcp and sign in to "atlassian" once.
  3. In each repo, once:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --project-setup
  4. Work:  /task PROJ-123   or   /task "describe the change"
  5. Then:  /loop 10m /pr-fix <PR number>   (review comments + failing CI + merge conflicts)
  6. Parallel jobs:  $BIN_DIR/new-job <name>   (one git worktree + Claude session per job)
Lessons live in $AI_HOME/memory — every /pr-fix makes the next /task smarter.
EOF
