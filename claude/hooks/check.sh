#!/usr/bin/env bash
# ai-native hook — enforces a project's lint/test rules from <repo>/.ai-native.json.
#
#   check.sh post-edit   PostToolUse (Edit|Write|MultiEdit): format + lint the edited file;
#                        remaining lint errors are sent back to Claude (exit 2).
#   check.sh pre-ship    PreToolUse (Bash): before `git commit`, `git push`, `gh pr create`,
#                        run every command in "check"; block the command if any fail (exit 2).
#                        Also blocks committing or pushing directly to the default branch.
#
# A project without .ai-native.json is left alone. Requires jq.
set -uo pipefail

mode="${1:-}"
input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

field() { jq -r "$1 // empty" <<<"$input" 2>/dev/null; }
block() { printf '%s\n' "$*" >&2; exit 2; }

cwd="$(field .cwd)"
cd "${cwd:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cfg="$root/.ai-native.json"
[[ -f "$cfg" ]] || exit 0
cd "$root" || exit 0

post_edit() {
  local file exts ok e fmt lint out
  file="$(field .tool_input.file_path)"
  [[ -n "$file" && -f "$file" ]] || exit 0
  case "$file" in "$root"/*) ;; *) exit 0 ;; esac

  exts="$(jq -r '(.extensions // []) | join(" ")' "$cfg")"
  if [[ -n "$exts" ]]; then
    ok=0
    for e in $exts; do [[ "$file" == *"$e" ]] && ok=1; done
    [[ $ok -eq 1 ]] || exit 0
  fi

  fmt="$(jq -r '.format // empty' "$cfg")"
  lint="$(jq -r '.lint // empty' "$cfg")"
  [[ -n "$fmt" ]] && bash -c "$fmt \"\$1\"" _ "$file" </dev/null >/dev/null 2>&1
  if [[ -n "$lint" ]]; then
    out="$(bash -c "$lint \"\$1\"" _ "$file" </dev/null 2>&1)" ||
      block "ai-native: lint errors in ${file#"$root"/} — fix them before continuing:
$(tail -n 40 <<<"$out")"
  fi
  exit 0
}

pre_ship() {
  local cmd ship_re branch default tmpidx tree key stamp c out failed=""
  cmd="$(field .tool_input.command)"
  ship_re='(^|[;&|({[:space:]])(git[[:space:]]+(commit|push)|gh[[:space:]]+pr[[:space:]]+create)([[:space:]]|$)'
  [[ "$cmd" =~ $ship_re ]] || exit 0

  # Never commit or push straight to the default branch.
  branch="$(git branch --show-current)"
  default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  default="${default#origin/}"; default="${default:-main}"
  if [[ "$cmd" =~ git[[:space:]]+(commit|push) && "$branch" == "$default" ]]; then
    block "ai-native: blocked — you are on '$default'. Create a feature branch first (git switch -c feat/<id>-<slug>)."
  fi
  if [[ "$cmd" =~ git[[:space:]]+push.*[[:space:]:]${default}([[:space:]]|$) ]]; then
    block "ai-native: blocked — pushing to '$default' is not allowed. Push the feature branch and open a PR."
  fi

  # Skip re-running checks when the working tree is identical to the last green run.
  tmpidx="$(mktemp)"
  cp "$(git rev-parse --git-path index)" "$tmpidx" 2>/dev/null
  tree="$(GIT_INDEX_FILE="$tmpidx" git add -A >/dev/null 2>&1 && GIT_INDEX_FILE="$tmpidx" git write-tree 2>/dev/null)"
  rm -f "$tmpidx"
  key="$tree:$(shasum <"$cfg" | cut -d' ' -f1)"
  stamp="$(git rev-parse --git-path ai-native-checks-ok)"
  [[ -n "$tree" && -f "$stamp" && "$(cat "$stamp")" == "$key" ]] && exit 0

  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if ! out="$(bash -c "$c" </dev/null 2>&1)"; then
      failed="${failed}\$ ${c}"$'\n'"$(tail -n 60 <<<"$out")"$'\n\n'
    fi
  done < <(jq -r '(.check // [])[]' "$cfg")

  if [[ -n "$failed" ]]; then
    block "ai-native: checks failed, so this command was blocked. Fix the problems and retry.
Never bypass the checks (no --no-verify, no weakening .ai-native.json or lint config).

$failed"
  fi
  [[ -n "$tree" ]] && printf '%s' "$key" >"$stamp"
  exit 0
}

case "$mode" in
  post-edit) post_edit ;;
  pre-ship)  pre_ship ;;
  *) exit 0 ;;
esac
