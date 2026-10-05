#!/usr/bin/env bash
# ai-native installer — adds /task, /pr-fix, and the ai-native subagents to Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/hoangtrankim/ai-native/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --project      # into ./.claude of the current repo
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Options:
#   --project      install skills/agents into ./.claude instead of ~/.claude
#   --ref <ref>    branch or tag to install (default: main)
#   --skip-mcp     don't register the Atlassian (Jira) MCP server
#   --uninstall    remove skills/agents (memory and briefs are kept)
# Env:
#   AI_NATIVE_REPO   GitHub "owner/repo" to download from (default below)
set -euo pipefail

REPO="${AI_NATIVE_REPO:-hoangtrankim/ai-native}"
REF="main"
TARGET="$HOME/.claude"
SKIP_MCP=0
UNINSTALL=0
AI_HOME="$HOME/.claude/ai-native"            # memory + briefs are always global
ATLASSIAN_MCP_URL="https://mcp.atlassian.com/v1/mcp/authv2"
SKILLS=(task pr-fix)
AGENTS=(ai-native-coder ai-native-reviewer)
MARKER=".ai-native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)   TARGET="$(pwd)/.claude" ;;
    --ref)       REF="${2:?--ref needs a value}"; shift ;;
    --skip-mcp)  SKIP_MCP=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)   sed -n '2,16p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

if [[ $UNINSTALL -eq 1 ]]; then
  for s in "${SKILLS[@]}"; do
    [[ -f "$TARGET/skills/$s/$MARKER" ]] && rm -rf "$TARGET/skills/$s" && info "Removed skill /$s"
  done
  for a in "${AGENTS[@]}"; do
    rm -f "$TARGET/agents/$a.md" && info "Removed agent $a"
  done
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
  3. In any GitHub repo:  /task PROJ-123   or   /task "describe the change"
  4. After review comments:  /pr-fix <PR number>
Lessons live in $AI_HOME/memory — every /pr-fix makes the next /task smarter.
EOF
