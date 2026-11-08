#!/bin/zsh
# Release helper.
#   scripts/release.sh bump <version>     set the version in meowlti + package.json, run the tests
#   scripts/release.sh ship <version> [--yes]
#                                         after the v<version> tag is pushed: build, sign and notarize the app,
#                                         create the GitHub release, update and push the Homebrew tap
#                                         (asks before anything goes out unless --yes). npm is done by the
#                                         tag push (.github/workflows/publish.yml) and approved by you with 2FA.
#   scripts/release.sh publish <version>  fallback when CI cannot: npm publish from this Mac as NPM_USER only
#   scripts/release.sh formula <version>  after the v<version> tag is on GitHub: write the Homebrew formula
#                                          (Formula/meowlti.rb for the jiyoung-e/homebrew-tap repo)
#   scripts/release.sh cask <version>     after MeowltiBar-<version>.zip is on the GitHub release: write the
#                                          Homebrew cask (Casks/meowltibar.rb for the same tap repo)
emulate -L zsh
setopt err_exit no_unset pipe_fail

ROOT="${0:A:h:h}"
REPO="jiyoung-e/meowlti"
NPM_USER="jiyoung-e"   # publish only from this npm account
TAP="${MEOWLTI_TAP:-$HOME/homebrew-tap}"   # local clone of github.com/jiyoung-e/homebrew-tap
GH="$(command -v gh || print /opt/homebrew/bin/gh)"
cmd="${1:-}" version="${2:-}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "usage: $0 bump|ship|publish|formula|cask <x.y.z>"; exit 1; }

case "$cmd" in
  bump)
    sed -i '' -E "s/^MEOWLTI_VERSION=.*/MEOWLTI_VERSION=$version/" "$ROOT/meowlti"
    sed -i '' -E "s/\"version\": \"[^\"]+\"/\"version\": \"$version\"/" "$ROOT/package.json"
    [[ "$("$ROOT/meowlti" --version)" == "meowlti $version" ]] || { print -u2 "version bump failed"; exit 1; }
    zsh "$ROOT/test/smoke.sh"
    [[ -s "$ROOT/release-notes/$version.md" ]] || print "\nWrite release-notes/$version.md (update window + GitHub release) and commit it with the bump."
    print "\nBumped to $version. Next: commit, tag v$version, push the commit and the tag, then:"
    print "  $0 ship $version"
    ;;
  publish)
    who="$(npm whoami 2>/dev/null || true)"
    [[ "$who" == "$NPM_USER" ]] || { print -u2 "npm is logged in as '${who:-nobody}', not '$NPM_USER' — run: npm login"; exit 1; }
    [[ "$(node -p "require('$ROOT/package.json').version")" == "$version" ]] || { print -u2 "package.json is not $version"; exit 1; }
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { print -u2 "working tree is not clean"; exit 1; }
    git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null || { print -u2 "tag v$version does not exist"; exit 1; }
    zsh "$ROOT/test/smoke.sh" >/dev/null || { print -u2 "tests failed"; exit 1; }
    # Check exactly what npm would upload for personal information.
    pkg="$(mktemp -d)"; trap 'rm -rf "$pkg"' EXIT
    (cd "$ROOT" && npm pack --pack-destination "$pkg" >/dev/null 2>&1) && tar -xzf "$pkg"/*.tgz -C "$pkg"
    "$ROOT/scripts/check-private.sh" dir "$pkg/package" || exit 1
    (cd "$ROOT" && npm publish --access public)
    ;;
  formula)
    url="https://github.com/$REPO/archive/refs/tags/v$version.tar.gz"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$url" -o "$tmp/src.tar.gz" || { print -u2 "could not download $url (is the tag pushed?)"; exit 1; }
    sha="$(shasum -a 256 "$tmp/src.tar.gz" | cut -d' ' -f1)"
    mkdir -p "$ROOT/packaging/homebrew"
    out="$ROOT/packaging/homebrew/meowlti.rb"
    sed -e "s|@URL@|$url|" -e "s|@SHA256@|$sha|" "$ROOT/packaging/homebrew/meowlti.rb.in" > "$out"
    mkdir -p "$tmp/src" && tar -xzf "$tmp/src.tar.gz" -C "$tmp/src"
    "$ROOT/scripts/check-private.sh" dir "$tmp/src" || { rm -f "$out"; exit 1; }
    print "Wrote $out — copy it to Formula/meowlti.rb in github.com/jiyoung-e/homebrew-tap and push."
    ;;
  cask)
    url="https://github.com/$REPO/releases/download/v$version/MeowltiBar-$version.zip"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "$url" -o "$tmp/app.zip" || { print -u2 "could not download $url (is the release uploaded?)"; exit 1; }
    sha="$(shasum -a 256 "$tmp/app.zip" | cut -d' ' -f1)"
    out="$ROOT/packaging/homebrew/meowltibar.rb"
    sed -e "s|@VERSION@|$version|" -e "s|@SHA256@|$sha|" "$ROOT/packaging/homebrew/meowltibar.rb.in" > "$out"
    print "Wrote $out — copy it to Casks/meowltibar.rb in github.com/jiyoung-e/homebrew-tap and push."
    ;;
  ship)
    yes=0; [[ "${3:-}" == --yes ]] && yes=1
    notes="$ROOT/release-notes/$version.md"
    upd="$ROOT/menubar/build.noindex/updates"
    zip="$upd/MeowltiBar-$version.zip"
    step() { print "\n==> $*"; }
    confirm() { (( yes )) && return 0; read -q "?$* [y/N] " || { print "\nstopped."; exit 1; }; print; }

    step "Checking"
    [[ "$("$ROOT/meowlti" --version)" == "meowlti $version" ]] || { print -u2 "meowlti is not $version — run: $0 bump $version"; exit 1; }
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { print -u2 "working tree is not clean"; exit 1; }
    [[ -s "$notes" ]] || { print -u2 "missing $notes"; exit 1; }
    tag="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version^{commit}")" || { print -u2 "tag v$version does not exist"; exit 1; }
    [[ "$tag" == "$(git -C "$ROOT" rev-parse HEAD)" ]] || { print -u2 "HEAD is not v$version"; exit 1; }
    [[ -n "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/v$version")" ]] || { print -u2 "tag v$version is not pushed"; exit 1; }
    "$GH" release view "v$version" --repo "$REPO" >/dev/null 2>&1 && { print -u2 "GitHub release v$version already exists"; exit 1; }
    [[ -d "$TAP/.git" && -z "$(git -C "$TAP" status --porcelain)" ]] || { print -u2 "$TAP is missing or not clean (set MEOWLTI_TAP)"; exit 1; }
    zsh "$ROOT/test/smoke.sh" >/dev/null || { print -u2 "tests failed"; exit 1; }

    step "Building, signing and notarizing MeowltiBar (takes a few minutes)"
    "$ROOT/menubar/build.sh" --release
    [[ -f "$zip" && -f "$upd/appcast.xml" ]] || { print -u2 "build did not produce $zip and appcast.xml"; exit 1; }
    # The app's code signatures name the Developer ID team, which is public by design: leave them out of the scan.
    app="$(mktemp -d)"; trap 'rm -rf "$app"' EXIT
    ditto -x -k "$zip" "$app"
    find "$app" -path '*/_CodeSignature/CodeResources' -delete
    cp "$upd/appcast.xml" "$app/"
    "$ROOT/scripts/check-private.sh" dir "$app" || exit 1

    step "Release notes"
    cat "$notes"
    confirm "Create the GitHub release v$version with these notes, MeowltiBar-$version.zip and appcast.xml?"
    "$GH" release create "v$version" "$zip" "$upd/appcast.xml" --repo "$REPO" \
      --title "meowlti $version" --notes-file "$notes" --verify-tag
    feed="$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml")"
    [[ "$feed" == *"<sparkle:shortVersionString>$version<"* ]] || { print -u2 "the latest appcast.xml is not $version yet — check the release"; exit 1; }

    step "Homebrew tap"
    zsh "$0" formula "$version"
    zsh "$0" cask "$version"
    git -C "$TAP" pull -q --ff-only
    cp "$ROOT/packaging/homebrew/meowlti.rb" "$TAP/Formula/meowlti.rb"
    cp "$ROOT/packaging/homebrew/meowltibar.rb" "$TAP/Casks/meowltibar.rb"
    "$ROOT/scripts/check-private.sh" dir "$TAP/Formula" && "$ROOT/scripts/check-private.sh" dir "$TAP/Casks" || exit 1
    brew="$(command -v brew || print /opt/homebrew/bin/brew)"
    [[ -x "$brew" ]] && "$brew" style "$TAP/Formula/meowlti.rb" "$TAP/Casks/meowltibar.rb"
    git -C "$TAP" --no-pager diff --stat
    confirm "Commit \"meowlti $version\" in the tap and push it?"
    git -C "$TAP" add Formula/meowlti.rb Casks/meowltibar.rb
    git -C "$TAP" commit -q -m "meowlti $version"
    git -C "$TAP" push -q origin HEAD

    step "Done"
    print "GitHub release: https://github.com/$REPO/releases/tag/v$version"
    print "npm: the tag push staged $version (Actions › publish). Approve it with 2FA:"
    print "  npm stage list meowlti   then   npm stage approve <stage-id>   (or npmjs.com › meowlti › Staged Packages)"
    ;;
  *) print -u2 "usage: $0 bump|ship|publish|formula|cask <x.y.z>"; exit 1 ;;
esac
