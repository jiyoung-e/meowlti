#!/bin/zsh
# Refuse to publish personal information.
#   scripts/check-private.sh staged          lines being committed + commit identity   (pre-commit hook)
#   scripts/check-private.sh range <a..b>    commits being pushed                       (pre-push hook)
#   scripts/check-private.sh dir <path>      files about to be packaged                 (release.sh)
#
# Personal patterns (emails, account ids, names…) are read from a file OUTSIDE the repository —
# by default ~/.config/meowlti/private-patterns, one case-insensitive extended regex per line —
# so the list itself is never published. Generic checks below catch common leaks without it.
emulate -L zsh
setopt no_unset pipe_fail

ROOT="${0:A:h:h}"
PATTERNS_FILE="${MEOWLTI_PRIVATE_PATTERNS:-$HOME/.config/meowlti/private-patterns}"

typeset -a pats=()
if [[ -f "$PATTERNS_FILE" ]]; then
  pats=(${(f)"$(grep -vE '^[[:space:]]*(#|$)' "$PATTERNS_FILE")"})
fi
# Generic: home-folder paths, real-looking emails, and UUIDs (account / org / session ids).
generic='/Users/[A-Za-z0-9._-]+/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
# Allowed: placeholders, GitHub noreply identities, obviously fake test ids.
allow='users\.noreply\.github\.com|@example\.com|you@company\.com|([0-9a-f])\1{7}-0000-0000-0000-0{12}|11111111-2222-3333-4444-555555555555'

found=0
scan() {   # scan <label> ; text on stdin
  local label="$1" text hits p
  text="$(cat)"
  [[ -n "$text" ]] || return 0
  hits="$(print -r -- "$text" | grep -nE "$generic" | grep -vE "$allow" || true)"
  for p in $pats; do
    hits+=$'\n'"$(print -r -- "$text" | grep -niE -- "$p" || true)"
  done
  hits="$(print -r -- "$hits" | grep -v '^$' | sort -u || true)"
  if [[ -n "$hits" ]]; then
    found=1
    print -u2 -- "check-private: possible personal information in $label:"
    print -u2 -- "${hits//$'\n'/$'\n'  }" | sed 's/^/  /' >&2
  fi
}

case "${1:-}" in
  staged)
    git -C "$ROOT" diff --cached -U0 --no-color | grep -E '^\+[^+]' | scan "staged changes"
    print -r -- "$(git -C "$ROOT" config user.name) <$(git -C "$ROOT" config user.email)>" | scan "commit identity"
    ;;
  range)
    [[ -n "${2:-}" ]] || { print -u2 "usage: $0 range <a..b>"; exit 2; }
    git -C "$ROOT" log -p --no-color --format='%an <%ae> %cn <%ce>%n%B' "$2" | grep -vE '^-' | scan "commits $2"
    ;;
  dir)
    [[ -d "${2:-}" ]] || { print -u2 "usage: $0 dir <path>"; exit 2; }
    local f
    for f in "$2"/**/*(.N); do
      file -b --mime "$f" | grep -q 'charset=binary' && continue
      scan "${f#$2/}" < "$f"
    done
    ;;
  *) print -u2 "usage: $0 staged | range <a..b> | dir <path>"; exit 2 ;;
esac

if (( found )); then
  print -u2 -- "check-private: refusing. Remove it, or if it is not personal, extend the allow-list in scripts/check-private.sh."
  exit 1
fi
(( ${#pats} )) || print -u2 -- "check-private: note — no personal pattern file at $PATTERNS_FILE; only generic checks ran."
exit 0
