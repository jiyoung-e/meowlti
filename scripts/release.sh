#!/bin/zsh
# Release helper. Only `publish` publishes (to npm); nothing here pushes to git.
#   scripts/release.sh bump <version>     set the version in meowlti + package.json, run the tests
#   scripts/release.sh publish <version>  after the v<version> tag is pushed: npm publish as NPM_USER only
#   scripts/release.sh formula <version>  after the v<version> tag is on GitHub: write the Homebrew formula
#                                          (Formula/meowlti.rb for the jiyoung-e/homebrew-tap repo)
emulate -L zsh
setopt err_exit no_unset pipe_fail

ROOT="${0:A:h:h}"
REPO="jiyoung-e/meowlti"
NPM_USER="jiyoung-e"   # publish only from this npm account
cmd="${1:-}" version="${2:-}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "usage: $0 bump|publish|formula <x.y.z>"; exit 1; }

case "$cmd" in
  bump)
    sed -i '' -E "s/^MEOWLTI_VERSION=.*/MEOWLTI_VERSION=$version/" "$ROOT/meowlti"
    sed -i '' -E "s/\"version\": \"[^\"]+\"/\"version\": \"$version\"/" "$ROOT/package.json"
    [[ "$("$ROOT/meowlti" --version)" == "meowlti $version" ]] || { print -u2 "version bump failed"; exit 1; }
    zsh "$ROOT/test/smoke.sh"
    print "\nBumped to $version. Next: commit, tag v$version, push, then:"
    print "  $0 publish $version"
    print "  $0 formula $version"
    ;;
  publish)
    who="$(npm whoami 2>/dev/null || true)"
    [[ "$who" == "$NPM_USER" ]] || { print -u2 "npm is logged in as '${who:-nobody}', not '$NPM_USER' — run: npm login"; exit 1; }
    [[ "$(node -p "require('$ROOT/package.json').version")" == "$version" ]] || { print -u2 "package.json is not $version"; exit 1; }
    [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { print -u2 "working tree is not clean"; exit 1; }
    git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null || { print -u2 "tag v$version does not exist"; exit 1; }
    zsh "$ROOT/test/smoke.sh" >/dev/null || { print -u2 "tests failed"; exit 1; }
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
    print "Wrote $out — copy it to Formula/meowlti.rb in github.com/jiyoung-e/homebrew-tap and push."
    ;;
  *) print -u2 "usage: $0 bump|publish|formula <x.y.z>"; exit 1 ;;
esac
