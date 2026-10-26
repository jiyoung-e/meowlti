# meowlti

Run several Claude and Codex accounts side by side on one Mac — the desktop apps **and** the CLIs —
each in its own profile with its own login, chats, Code sessions and settings.

```
meowlti add work            # create a profile
meowlti open work           # Claude desktop signed in to the "work" account, next to your usual one
meowlti claude work         # Claude Code CLI with the "work" account
meowlti bind work ~/company # plain `claude` / `codex` inside ~/company now use "work"
```

> meowlti is an independent tool. It is not affiliated with or endorsed by Anthropic or OpenAI.
> Use separate accounts the way their terms allow — for example, distinct paid accounts for distinct work.
> Switching accounts to get around a usage limit may violate those terms.

## Requirements

- macOS (Apple silicon or Intel)
- `zsh` (built in) and `python3` (from the Xcode Command Line Tools: `xcode-select --install`, or Homebrew)
- For desktop profiles: Claude desktop (`/Applications/Claude.app`) and/or the ChatGPT/Codex app (`/Applications/ChatGPT.app`)
- For CLI profiles: `claude` (Claude Code) and/or `codex` on your `PATH`

## Install

### CLI

npm:

```sh
npm install -g meowlti
```

Straight from GitHub (pick a release tag):

```sh
npm install -g github:jiyoung-e/meowlti#v0.1.0
```

Or download the single script and put it on your `PATH`:

```sh
curl -fsSL https://raw.githubusercontent.com/jiyoung-e/meowlti/v0.1.0/meowlti -o ~/.local/bin/meowlti && chmod +x ~/.local/bin/meowlti
```

### Menu bar app (MeowltiBar)

Download `MeowltiBar-<version>.zip` from [Releases](https://github.com/jiyoung-e/meowlti/releases),
unzip it and move `MeowltiBar.app` to `/Applications`. It is signed and notarized, and needs the `meowlti`
CLI on your `PATH`.

From 0.1.1 on, MeowltiBar updates itself with [Sparkle](https://sparkle-project.org): it looks at this
repository's latest release for a newer version (it asks before checking automatically) and you can use
**업데이트 확인…** in its menu. Updates are verified with an EdDSA signature and Apple's notarization.
0.1.0 has no updater, so replace it by hand once.

Optional — let plain `claude` / `codex` pick the profile bound to the current folder:

```sh
meowlti shell-init --install    # appends: eval "$(meowlti shell-init zsh)"  to ~/.zshrc
```

## How profiles work

Each profile is a folder under `~/.meowlti/profiles/<name>/`:

| Folder | Used as | Holds |
|---|---|---|
| `desktop/` | Claude desktop `--user-data-dir` | desktop login, chats, desktop state |
| `claude/` | `CLAUDE_CONFIG_DIR` (CLI **and** the desktop Code tab) | CLI login, Code sessions, settings, memory |
| `codex/` | `CODEX_HOME` | Codex CLI login, sessions, config |
| `codex-desktop/` | Codex desktop `--user-data-dir` (experimental) | Codex desktop state |

Your existing setup (`~/.claude`, `~/.codex`, and the apps you launch normally) is never modified.

The desktop login and the CLI login are separate: sign in once in the profile's desktop window and,
if you use the CLI, once with `meowlti claude <name> auth login` (Codex: `meowlti codex <name> login`).
Use the same account for both — otherwise one profile mixes two accounts (shared sessions and memory),
which `meowlti ls` and MeowltiBar flag with ⚠.

## Commands

### Profiles

| Command | |
|---|---|
| `meowlti add <name>` | Create a profile (and a `Claude (<name>).app` launcher) |
| `meowlti ls [--cli-auth]` | Profiles, accounts, running apps (`--cli-auth` also checks Claude CLI login) |
| `meowlti label <name> [<text>\|--clear]` | Display name shown in lists. The profile id/folder never changes |
| `meowlti rm <name> [--yes]` | Quit the profile's apps and move its folder to the Trash |
| `meowlti launcher <name\|default>` | (Re)create the `Claude (<name>).app` launcher |

Profile names use lowercase letters, digits and `-` (max 32 characters).

### Desktop apps

| Command | |
|---|---|
| `meowlti open <name> [claude\|codex]` | Launch the desktop app for the profile, or bring its window to the front |
| `meowlti quit <name> [claude\|codex]` | Quit only that profile's window (graceful, like ⌘Q) |
| `meowlti login <name> [--exclusive]` | Open the profile's window for sign-in and wait until it is signed in (see below) |

**Your normal Claude.** `default` means your usual setup — the apps started without a profile,
`~/.claude` and `~/.codex`. While profile windows are open, clicking Claude in the Dock may just raise one of
them, for example after your main Claude quit or crashed. `meowlti open default` (or the `Claude (default).app`
launcher, made with `meowlti launcher default`) always opens or raises your normal Claude.
`default` works with `open`, `quit`, `login` and `ls`.

**Signing in to a desktop profile.** Use **Continue with email** in the profile's window: it works while your
other Claude windows stay open. Google sign-in returns to the app through a `claude://` link, and macOS hands that
link to the Claude window that started first (usually your normal one), not to the profile. For Google, run
`meowlti login <name> --exclusive` (or MeowltiBar › Google로 로그인…): it quits your other Claude windows, waits
while you sign in to the profile, and reopens them. Run it from Terminal or MeowltiBar, not from a Claude
window's Code tab. Each exclusive sign-in is logged in `~/.meowlti/logs/`.

### CLIs

| Command | |
|---|---|
| `meowlti claude <name> [args...]` | Claude Code with the profile (adds a status line showing the profile) |
| `meowlti codex <name> [args...]` | Codex CLI with the profile |

### Folder bindings and shell integration

| Command | |
|---|---|
| `meowlti bind <profile> [folder] [--file]` | Use the profile in that folder and below (default: current folder) |
| `meowlti unbind [folder]` | Remove the folder's binding |
| `meowlti which [folder]` | Which profile applies here |
| `meowlti bindings [profile]` | List bindings |
| `meowlti shell-init [zsh\|bash]` | Print the `claude` / `codex` shell functions |
| `meowlti shell-init --install` / `--status` | Add them to `~/.zshrc` / check |

Bindings are stored in `~/.meowlti/bindings.tsv` so nothing is written into your projects. With `--file`, a
`.meowlti` file is written into the folder instead (add it to `.gitignore` in shared repositories).
The nearest binding wins; `command claude` bypasses meowlti. Bindings apply to the CLIs, not to the desktop Code tab.

### Status line

When Claude Code is started through meowlti, its status line starts with the profile, e.g.
`🐱 work · you@company.com`, followed by the status line you already use (if the profile has one).
It is passed with `--settings`, so no settings file is changed. Set `MEOWLTI_NO_STATUSLINE=1` to turn it off;
passing your own `--settings` also skips it.

### Sharing settings between profiles

| Command | |
|---|---|
| `meowlti shared <name> claude\|codex` | Shareable items and whether each is shared |
| `meowlti share <name> claude\|codex <item>...` | Symlink items from `~/.claude` / `~/.codex` into the profile |
| `meowlti unshare <name> claude\|codex <item>...` | Remove those symlinks |

Logins, sessions, history and `.claude.json` / `auth.json` can never be shared.

### Continuing a Code session in another profile

| Command | |
|---|---|
| `meowlti sessions <name>` | Code sessions of a profile (CLI and desktop Code tab) |
| `meowlti copy-session <from> <id> <to> [--allow-cross-org]` | Copy a session so it can be continued under the other account |

The original stays where it was. The target's Claude window must be closed while copying.
Copying between accounts of different organizations is refused unless `--allow-cross-org` is given —
the whole conversation, including code and file contents, moves to the other organization's account.
Desktop chats live on the server and cannot be copied.

### JSON output

Add `--json` to any command (except the pass-through `claude`, `codex`, `exec`) for machine-readable output:
data commands print JSON documents, actions print `{"ok":true,"messages":[...]}`, and errors print
`{"error":"..."}` to stderr with exit code 1.

```sh
meowlti --json ls
```

## Environment variables

| Variable | |
|---|---|
| `MEOWLTI_HOME` | Where profiles live (default `~/.meowlti`) |
| `MEOWLTI_CLAUDE_APP`, `MEOWLTI_CODEX_APP` | Desktop app bundles, if not in `/Applications` |
| `MEOWLTI_PYTHON` | python3 to use |
| `MEOWLTI_NO_STATUSLINE` | Disable the status line |
| `MEOWLTI_LAUNCHERS`, `MEOWLTI_TRASH` | Where launchers go / where `rm` moves profiles |

## Caveats

- Desktop features rely on how the Claude and ChatGPT apps behave today (`--user-data-dir`, the `claude://` link,
  the Code tab's local session files). These are not documented interfaces; an app update can break them.
- Codex desktop profiles are experimental.
- Profiles are ordinary folders, not a security boundary. Anyone with access to your user account can read them.
- While `meowlti login` waits, a `claude://` link copied to the clipboard is relayed to the profile's window
  and the clipboard is cleared (browsers usually don't let you copy that link, so email or `--exclusive` is the normal path).

## Uninstall

```sh
npm uninstall -g meowlti      # or delete the script you downloaded
```

Then delete `/Applications/MeowltiBar.app`, remove the `meowlti` lines from `~/.zshrc` and, if you no longer need the profiles, `~/.meowlti`.

## Development

```sh
zsh scripts/setup-dev.sh   # new Mac: noreply commit identity, privacy hooks, signing/notary/Sparkle checks
zsh test/smoke.sh          # uses a temporary MEOWLTI_HOME and fake claude/codex binaries
menubar/build.sh           # local MeowltiBar build (ad-hoc signed, no updater)
```

Releases (on the Mac that holds the signing keys): `scripts/release.sh bump <version>`, commit and tag,
`menubar/build.sh --release` (signed, notarized app + Sparkle `appcast.xml`), upload both to the GitHub
release, then `scripts/release.sh publish <version>` for npm.

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free for personal use, hobby projects, research, and
noncommercial organizations. Commercial use (including use at work for a for-profit company) needs a
separate license: open an issue at https://github.com/jiyoung-e/meowlti to ask.

Required Notice: Copyright 2026 jiyoung-e (https://github.com/jiyoung-e/meowlti)
