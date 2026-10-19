#!/bin/zsh
# Smoke tests for the meowlti CLI. Uses a throwaway MEOWLTI_HOME and fake `claude` / `codex`
# binaries, so it never touches real profiles, accounts or the desktop apps.
#   zsh test/smoke.sh            (exit 0 = all passed)
emulate -L zsh
setopt no_unset pipe_fail

ROOT="${0:A:h:h}"
M="$ROOT/meowlti"
T="$(mktemp -d "${TMPDIR:-/tmp}/meowlti-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

export MEOWLTI_HOME="$T/home" MEOWLTI_TRASH="$T/trash" MEOWLTI_LAUNCHERS="$T/launchers"
mkdir -p "$T/bin" "$T/proj/company/sub" "$T/proj/side"
for tool in claude codex; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/zsh
print -r -- "FAKE $tool CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR:--} CODEX_HOME=\${CODEX_HOME:--} PROFILE=\${MEOWLTI_PROFILE:--} ARGS=\$*"
EOF
  chmod +x "$T/bin/$tool"
done
export PATH="$T/bin:$PATH"

pass=0 fail=0
ok()   { (( pass++ )); print -r -- "ok   $1"; }
bad()  { (( fail++ )); print -r -- "FAIL $1"; [[ -n "${2:-}" ]] && print -r -- "     got: $2"; }
# expect <name> <substring> <command...>  — stdout+stderr must contain substring
expect() {
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  [[ "$out" == *"$want"* ]] && ok "$name" || bad "$name" "$out"
}
# expect_fail <name> <command...>  — must exit non-zero
expect_fail() {
  local name="$1"; shift
  "$@" >/dev/null 2>&1 && bad "$name" "exited 0" || ok "$name"
}
json_ok() {   # json_ok <name> <python expr on d> <command...>
  local name="$1" expr="$2"; shift 2
  local out; out="$("$@" 2>/dev/null)"
  if print -r -- "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($expr) else 1)" 2>/dev/null
  then ok "$name"; else bad "$name" "$out"; fi
}

# --- basics
expect "version" "meowlti " "$M" --version
json_ok "version --json" 'd["version"]' "$M" --json --version
expect "ls shows default" "default" "$M" ls
expect_fail "default is reserved" "$M" add default
expect_fail "default rejects profile-only commands" "$M" label default x

# --- finding the default (main) instance among profile instances
F="$(sed -n '/^find_pid() {/,/^}/p' "$M")"
CL=/Applications/Claude.app/Contents/MacOS/Claude
fp() { zsh -c "setopt extended_glob; $F; PS_SNAPSHOT=\$1; find_pid '$CL' \"\$2\"" _ "$1" "$2"; }
snap_profiles_only="  11 $CL --user-data-dir=/p/work/desktop
  12 $CL --user-data-dir=/p/dev/desktop"
[[ -z "$(fp "$snap_profiles_only" "")" ]] && ok "default not found when only profiles run" || bad "default not found when only profiles run"
[[ "$(fp "$snap_profiles_only
  13 $CL" "")" == 13 ]] && ok "default found" || bad "default found"
[[ "$(fp "$snap_profiles_only
  14 $CL --some-flag" "")" == 14 ]] && ok "default found with extra flags" || bad "default found with extra flags"
[[ "$(fp "  15 $CL --user-data-dir=/p/work2/desktop
  16 $CL --user-data-dir=/p/work/desktop" /p/work/desktop)" == 16 ]] && ok "profile match is exact" || bad "profile match is exact"

# --- profiles
expect "add work" "Created profile 'work'" "$M" add work
[[ -d "$T/launchers/Claude (work).app" ]] && ok "launcher created in MEOWLTI_LAUNCHERS" || bad "launcher created in MEOWLTI_LAUNCHERS"
"$M" add personal >/dev/null
expect_fail "add duplicate" "$M" add work
expect_fail "reject bad name" "$M" add "Bad Name"
expect_fail "reject invisible char" "$M" add $'work '
expect "label set" "set to 'Company'" "$M" label work "  Company  "
expect "label trimmed" "Company" "$M" label work
json_ok "ls --json" 'd[0]["name"]=="default" and [p["label"] for p in d if p["name"]=="work"]==["Company"] and len(d)==3' "$M" --json ls
json_ok "error --json" '"error" in d' zsh -c "'$M' --json open nope 2>&1"

# --- sharing
mkdir -p "$T/fakehome/.claude/skills"; print '{}' > "$T/fakehome/.claude/settings.json"
expect "share" "Shared" env HOME="$T/fakehome" "$M" share work claude skills
[[ -L "$MEOWLTI_HOME/profiles/work/claude/skills" ]] && ok "share makes symlink" || bad "share makes symlink"
json_ok "shared --json" 'any(i["item"]=="skills" and i["state"]=="shared" for i in d)' env HOME="$T/fakehome" "$M" --json shared work claude
expect_fail "refuse sharing account data" "$M" share work claude projects
expect "unshare" "Unshared" env HOME="$T/fakehome" "$M" unshare work claude skills

# --- folder bindings
cd "$T/proj"
expect "bind registry" "Bound" "$M" bind work company
expect "bind file" ".meowlti" "$M" bind personal side --file
expect_fail "refuse binding home" "$M" bind work "$HOME"
expect "which subfolder" "work (bound at" "$M" which company/sub
expect "which file" "by its .meowlti file" "$M" which side
json_ok "which --json unbound" 'd["profile"] is None' "$M" --json which "$T/proj"
json_ok "bindings --json" 'len(d)==1 and d[0]["profile"]=="work"' "$M" --json bindings

# --- exec / shell-init / status line
expect "exec uses profile" "CLAUDE_CONFIG_DIR=$MEOWLTI_HOME/profiles/work/claude" zsh -c "cd company/sub && '$M' exec claude x"
expect "exec injects status line" "statusLine" zsh -c "cd company && '$M' exec claude x"
expect "user --settings wins" "ARGS=--settings mine.json" zsh -c "cd company && '$M' exec claude --settings mine.json"
expect "exec codex uses CODEX_HOME" "CODEX_HOME=$MEOWLTI_HOME/profiles/personal/codex" zsh -c "cd side && '$M' exec codex"
expect "exec unbound passes through" "CLAUDE_CONFIG_DIR=- CODEX_HOME=- PROFILE=- ARGS=hi" zsh -c "cd '$T' && '$M' exec claude hi"
expect "--json after exec goes to tool" "ARGS=--json" zsh -c "cd '$T' && '$M' exec claude --json"
expect "shell-init zsh" "using profile 'work'" zsh -fc "export PATH='$ROOT:$PATH'; eval \"\$(meowlti shell-init zsh)\"; cd company && claude"
expect "shell-init bash" "using profile 'personal'" bash -c "export PATH='$ROOT:$PATH'; eval \"\$(meowlti shell-init bash)\"; cd side && codex"
expect "status line alone" "Company" zsh -c "print '{}' | MEOWLTI_PROFILE=work '$M' statusline"
expect "status line chains previous" "│ PREV" zsh -c "print '{}' | MEOWLTI_PROFILE=work MEOWLTI_PREV_STATUSLINE='echo PREV' '$M' statusline"
expect "unbind" "Unbound" "$M" unbind company
cd "$T"

# --- Code sessions (synthetic data)
SID=11111111-2222-3333-4444-555555555555
ACCT=aaaaaaaa-0000-0000-0000-000000000000 ORG=bbbbbbbb-0000-0000-0000-000000000000
for p in work personal; do
  print -r -- "{\"lastKnownAccountUuid\":\"$ACCT\",\"oauth:tokenCacheV2\":\"x\"}" > "$MEOWLTI_HOME/profiles/$p/desktop/config.json"
  print -r -- "{\"oauthAccount\":{\"emailAddress\":\"$p@example.com\",\"organizationUuid\":\"$ORG\"}}" > "$MEOWLTI_HOME/profiles/$p/claude/.claude.json"
done
mkdir -p "$MEOWLTI_HOME/profiles/work/claude/projects/-tmp-x" "$MEOWLTI_HOME/profiles/work/desktop/claude-code-sessions/$ACCT/$ORG"
print -r -- "{\"type\":\"user\",\"cwd\":\"/tmp/x\",\"message\":{\"content\":\"hello there\"}}" > "$MEOWLTI_HOME/profiles/work/claude/projects/-tmp-x/$SID.jsonl"
print -r -- "{\"sessionId\":\"local_x\",\"cliSessionId\":\"$SID\",\"title\":\"Demo\",\"cwd\":\"/tmp/x\",\"lastActivityAt\":1}" \
  > "$MEOWLTI_HOME/profiles/work/desktop/claude-code-sessions/$ACCT/$ORG/local_x.json"
json_ok "sessions --json" 'd[0]["id"]=="'$SID'" and d[0]["title"]=="Demo"' "$M" --json sessions work
expect "copy-session" "Copied 'Demo'" "$M" copy-session work "$SID" personal
expect_fail "copy-session duplicate" "$M" copy-session work "$SID" personal
expect "copied session listed" "$SID" "$M" sessions personal
expect_fail "copy-session bad id" "$M" copy-session work "x;rm" personal
print -r -- "{\"oauthAccount\":{\"organizationUuid\":\"cccccccc-0000-0000-0000-000000000000\"}}" > "$MEOWLTI_HOME/profiles/personal/claude/.claude.json"
rm -rf "$MEOWLTI_HOME/profiles/personal/claude/projects"
expect "cross-org refused" "CROSS_ORG" "$M" copy-session work "$SID" personal
expect "cross-org allowed with flag" "Copied" "$M" copy-session work "$SID" personal --allow-cross-org

# --- removal
expect "rm --yes" "Moved to" "$M" rm personal --yes
[[ -d "$T/trash" && -n "$(ls "$T/trash")" ]] && ok "rm goes to trash" || bad "rm goes to trash"

print -- "\n$pass passed, $fail failed"
(( fail == 0 ))
