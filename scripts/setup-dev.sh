#!/bin/zsh
# Prepare a Mac for meowlti development and releases. Safe to run again; it only fills in what is missing.
#
#   zsh setup-dev.sh                 set up (clones ~/meowlti first if run outside the repo)
#   zsh setup-dev.sh --p12 <file>    also import a Developer ID certificate exported as .p12
#   zsh setup-dev.sh --check         report only, change nothing
#
# Secrets never pass through this script: macOS asks for the .p12 password, notarytool asks for the
# Apple ID / app-specific password, and the Sparkle private key is created inside the login keychain.
emulate -L zsh
setopt no_unset pipe_fail

REPO_URL="https://github.com/jiyoung-e/meowlti.git"
GIT_NAME="jiyoung-e"
GIT_EMAIL="68890429+jiyoung-e@users.noreply.github.com"   # GitHub noreply: keeps real emails out of commits
NOTARY_PROFILE="meowlti-personal"
SPARKLE_ACCOUNT="meowlti"
CONF_DIR="$HOME/.config/meowlti"

CHECK=0 P12=""
while (( $# )); do
  case "$1" in
    --check) CHECK=1 ;;
    --p12) P12="${2:-}"; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) print -u2 "unknown option: $1"; exit 2 ;;
  esac
  shift
done

typeset -a summary
okay() { summary+=("✅ $1"); print -- "✅ $1"; }
todo() { summary+=("⚠️  $1"); print -- "⚠️  $1"; }
ask()  { (( CHECK )) && return 1; print -n -- "$1 [y/N] "; local a; read -r a; [[ "$a" == [yY]* ]]; }

print -- "== tools"
if xcode-select -p >/dev/null 2>&1; then okay "Xcode Command Line Tools"
else todo "Xcode Command Line Tools missing — run: xcode-select --install (then rerun this script)"; exit 1; fi
for t in git python3 swiftc codesign; do
  whence -p $t >/dev/null && okay "$t" || todo "$t not found"
done
whence -p gh  >/dev/null && okay "gh (GitHub CLI)" || todo "gh not found — needed to upload releases (brew install gh)"
whence -p npm >/dev/null && okay "npm" || todo "npm not found — needed only to publish the CLI to npm"

print -- "\n== repository"
ROOT="$(git -C "${0:A:h}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" || ! -f "$ROOT/meowlti" ]]; then
  ROOT="$HOME/meowlti"
  if [[ -d "$ROOT/.git" ]]; then okay "using $ROOT"
  elif (( CHECK )); then todo "no checkout at $ROOT"; ROOT=""
  else git clone "$REPO_URL" "$ROOT" && okay "cloned into $ROOT" || { todo "git clone failed"; exit 1; }; fi
else
  okay "using $ROOT"
fi

if [[ -n "$ROOT" ]]; then
  print -- "\n== commit identity and privacy hooks"
  if [[ "$(git -C "$ROOT" config user.email)" == "$GIT_EMAIL" ]]; then okay "commit author is the GitHub noreply address"
  elif (( CHECK )); then todo "commit author is not the noreply address (run without --check to fix)"
  else git -C "$ROOT" config user.name "$GIT_NAME"; git -C "$ROOT" config user.email "$GIT_EMAIL"; okay "commit author set to the noreply address"; fi

  hooks="$ROOT/.git/hooks"
  if [[ -x "$hooks/pre-commit" && -x "$hooks/pre-push" ]] && grep -q check-private "$hooks/pre-commit" "$hooks/pre-push"; then
    okay "pre-commit / pre-push privacy hooks installed"
  elif (( CHECK )); then todo "privacy hooks missing"
  else
    cat > "$hooks/pre-commit" <<'HOOK'
#!/bin/sh
exec "$(git rev-parse --show-toplevel)/scripts/check-private.sh" staged
HOOK
    cat > "$hooks/pre-push" <<'HOOK'
#!/bin/sh
# stdin: <local ref> <local sha> <remote ref> <remote sha>
root="$(git rev-parse --show-toplevel)"
zero=0000000000000000000000000000000000000000
while read -r lref lsha rref rsha; do
  [ "$lsha" = "$zero" ] && continue
  if [ "$rsha" = "$zero" ]; then range="$lsha"; else range="$rsha..$lsha"; fi
  "$root/scripts/check-private.sh" range "$range" || exit 1
done
HOOK
    chmod +x "$hooks/pre-commit" "$hooks/pre-push"
    okay "privacy hooks installed"
  fi
fi

print -- "\n== local config ($CONF_DIR, never committed)"
(( CHECK )) || { mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"; }
if [[ -s "$CONF_DIR/private-patterns" ]]; then okay "private-patterns present"
else todo "private-patterns missing — copy it from your other Mac (it lists your emails/ids, so it is not in the repo)"; fi

print -- "\n== Developer ID certificate"
if [[ -n "$P12" ]] && (( ! CHECK )); then
  [[ -f "$P12" ]] || { todo "$P12 not found"; exit 1; }
  print -- "macOS will ask for the .p12 password."
  security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -T /usr/bin/codesign \
    && okay "imported $P12 (delete the .p12 file once you have a backup)" || todo "certificate import failed"
fi
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n -E 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)"
if [[ -n "$IDENTITY" ]]; then
  okay "Developer ID Application certificate found"
  if (( ! CHECK )); then
    print -r -- "MEOWLTI_SIGN_IDENTITY=\"$IDENTITY\"
MEOWLTI_NOTARY_PROFILE=\"$NOTARY_PROFILE\"" > "$CONF_DIR/signing.env"
    chmod 600 "$CONF_DIR/signing.env"
    okay "wrote $CONF_DIR/signing.env"
  fi
else
  todo "no Developer ID Application certificate — import your .p12 (rerun with --p12 <file>) or create one in Xcode › Settings › Accounts › Manage Certificates"
fi

print -- "\n== notarization credentials"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  okay "notary profile '$NOTARY_PROFILE'"
elif ask "Store notarization credentials now? (you'll be asked for Apple ID, team ID and an app-specific password)"; then
  xcrun notarytool store-credentials "$NOTARY_PROFILE" && okay "notary profile '$NOTARY_PROFILE' stored" || todo "storing notary credentials failed"
else
  todo "notary profile missing — run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi

if [[ -n "$ROOT" ]]; then
  print -- "\n== Sparkle update signing key"
  SPARKLE="$("$ROOT/menubar/fetch-sparkle.sh" 2>/dev/null || true)"
  KEYFILE="$ROOT/menubar/sparkle-public-key.txt"
  if [[ -z "$SPARKLE" ]]; then
    todo "could not download Sparkle tools"
  else
    # The lookup prints errors on stdout, so trust only a zero exit and a base64 Ed25519 key (44 chars).
    sparkle_pub() {
      local out; out="$("$SPARKLE/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null)" || return 1
      out="$(print -r -- "$out" | tail -1 | tr -d '[:space:]')"
      [[ "$out" =~ '^[A-Za-z0-9+/]{43}=$' ]] && print -r -- "$out"
    }
    pub="$(sparkle_pub || true)"
    if [[ -z "$pub" ]] && ask "No Sparkle key on this Mac. Create one now (stored only in this Mac's keychain)?"; then
      "$SPARKLE/bin/generate_keys" --account "$SPARKLE_ACCOUNT" >/dev/null
      pub="$(sparkle_pub || true)"
      [[ -n "$pub" ]] && print -- "Back up the private key to your password manager, then delete the file:
  $SPARKLE/bin/generate_keys --account $SPARKLE_ACCOUNT -x ~/Desktop/meowlti-sparkle-key.txt"
    fi
    if [[ -z "$pub" ]]; then
      todo "no Sparkle signing key (account '$SPARKLE_ACCOUNT') in this keychain"
    else
      okay "Sparkle signing key in this Mac's keychain"
      if [[ -s "$KEYFILE" && "$(tr -d '[:space:]' < "$KEYFILE")" == "$pub" ]]; then
        okay "menubar/sparkle-public-key.txt matches"
      elif [[ -s "$KEYFILE" ]]; then
        todo "menubar/sparkle-public-key.txt does NOT match this Mac's key — releases from here would not install as updates"
      elif (( CHECK )); then
        todo "menubar/sparkle-public-key.txt missing"
      else
        print -r -- "$pub" > "$KEYFILE"
        okay "wrote menubar/sparkle-public-key.txt (public key — commit it)"
      fi
    fi
  fi

  print -- "\n== tests"
  zsh "$ROOT/test/smoke.sh" >/dev/null 2>&1 && okay "smoke tests pass" || todo "smoke tests failed (run: zsh $ROOT/test/smoke.sh)"
fi

print -- "\n== summary"
print -l -- $summary
