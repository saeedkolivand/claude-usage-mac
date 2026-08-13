# claude-usage-mac

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Platform](https://img.shields.io/badge/macOS-14%2B-black.svg)
![Swift](https://img.shields.io/badge/built%20with-Swift%205.9-f05138.svg)
[![Homebrew](https://img.shields.io/badge/Homebrew-saeedkolivand%2Ftap-d97757.svg)](https://github.com/saeedkolivand/homebrew-tap)
[![Site](https://img.shields.io/badge/site-claude--usage--mac.iamsaeed.dev-38bdf8.svg)](https://claude-usage-mac.iamsaeed.dev)
[![Downloads](https://img.shields.io/github/downloads/saeedkolivand/claude-usage-mac/total.svg?color=blue)](../../releases)
[![Stars](https://img.shields.io/github/stars/saeedkolivand/claude-usage-mac?color=e3b341)](../../stargazers)

Claude Code usage in the macOS menu bar and as a desktop widget — session and
weekly limit percentages, token counts, and estimated cost.

A native port of [claude-usage-streamdeck-plugin](https://github.com/saeedkolivand/claude-usage-streamdeck-plugin)
for people who don't own a Stream Deck.

![Claude Usage: the menu bar popover beside the medium and small widgets](docs/gallery/hero.png)

> **Status: built, not yet run on real hardware.** Everything compiles, tests
> pass, and the UI is reviewed through rendered snapshots — but the project is
> developed on Windows, so nobody has launched it on a Mac yet. See
> [Unverified](#unverified) before trusting it.

## Install

Requires macOS 14 or later.

```sh
brew tap saeedkolivand/tap
brew trust --cask saeedkolivand/tap/claude-usage
brew install --cask claude-usage
```

The `trust` step is required. Since [Homebrew 6.0](https://brew.sh/2026/06/11/homebrew-6.0.0/),
third-party taps must be explicitly trusted before Homebrew will evaluate their
Ruby — a response to a [compromised tap being used to ship malware](https://docs.brew.sh/Tap-Trust).
`--cask <tap>/<cask>` trusts only this one cask; `brew trust saeedkolivand/tap`
would trust everything in the tap, now and in future.

Or download the DMG from [Releases](../../releases), or build from source with
`brew install xcodegen && ./build.sh`.

The widget shows up in the widget gallery once the app has run at least once.

Upgrading from 0.2 or earlier? Remove any placed widget and drag out a fresh
one. Widgets became configurable in 0.3 and macOS cannot migrate a widget across
that change — it refuses the timeline request rather than rendering. Widgets
configured under 0.3.0 or 0.3.1 need their profile picked again for the same
reason.

On 0.3.9? Its auto-update swapped the app bundle without re-registering the
widget extension, so placed widgets froze on the render they happened to be
showing and newly added ones sat on a grey placeholder. 0.4.0 fixes that, but
0.4.0 is *installed by 0.3.9's updater* — so it breaks the widget one last time
on the way in. After it lands, run `killall chronod`, and remove and re-add any
widget that still won't populate. Updates from 0.4.0 onward re-register as part
of the install and need none of this.

Builds are ad-hoc signed, not notarized, so macOS quarantines them. The cask
clears that for you; if you install the DMG by hand, run:

```sh
xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"
```

The cask is in a personal tap rather than `homebrew/cask` because that repo
[drops casks failing Gatekeeper checks from 2026-09-01](https://github.com/orgs/Homebrew/discussions/6334),
and `--no-quarantine` [is being removed](https://github.com/Homebrew/brew/issues/20755).

## Gallery

| | |
|---|---|
| ![Small widget](docs/gallery/widget-small.png) | ![Medium widget](docs/gallery/widget-medium.png) |
| **Small** — the 5-hour window, and when it resets. | **Medium** — both limits, plus today and this week. |
| ![Large widget](docs/gallery/widget-large.png) | ![Project-scoped widget](docs/gallery/widget-project.png) |
| **Large** — adds per-model limits, the burn rate, and a 13-week heatmap. | **Project-scoped** — one directory's tokens and cost. No gauges: limits are account-level. |

![The menu bar popover](docs/gallery/menu.png)

Every widget carries its own configuration, so you can place one per account or
one per project, side by side.

## What it reads

Two sources, both already on your machine. Nothing is sent anywhere.

| Source | Gives |
|---|---|
| `api.anthropic.com/api/oauth/usage`, using the OAuth token Claude Code already stored | 5-hour and 7-day limit utilization, the per-model weekly windows and purchased extra usage where the plan has them, and when each resets |
| `~/.claude/projects/**/*.jsonl` | today / this week / current session token counts, estimated cost, and the split by model |

Opus and Sonnet weekly windows come back null on plans without them, and nothing
renders a placeholder for a limit an account doesn't have. `usage-cli` prints
them when present, which is the quickest way to find out whether yours does.

The burn rate is measured, not reported: percentage points per hour across this
process's own readings of the 5-hour window. It says nothing until two polls of
active use have gone by, and says nothing about time-to-limit when the window
resets before it could fill — which is the usual case.

The token is read from `<config dir>/.credentials.json`, falling back to the login
Keychain. We never log in, and the only write we ever make is described under
*Token refresh* below; nothing is transmitted except the authenticated requests
above.

Claude Code names that Keychain item after the config dir it was authenticated
from: `Claude Code-credentials` for the default `~/.claude`, and
`Claude Code-credentials-<first 8 hex of sha256(config dir)>` for anything
relocated with `CLAUDE_CONFIG_DIR`. Each service name is queried by service
alone, deliberately unpinned from any account name: real machines carry the
macOS short username there, not a fixed value, and pinning has already shipped
one release that couldn't find its own token.

An expired credential never hides a live one behind it: a leftover
`.credentials.json`, or a dead Keychain item sharing a service name with a
current one, is remembered but stepped over, and only reported if every other
candidate misses.

**Token refresh.** When the access token expires (they live ~8 hours), the app
refreshes it itself with the same OAuth flow the CLI uses, and writes the
rotated refresh token back to `.credentials.json` — atomically, preserving
every other field — so the CLI stays logged in. This only works for
**file-backed** profiles: the Keychain item belongs to the CLI and a write from
another process risks consuming the single-use rotation without persisting it,
which would log the CLI out. Keychain-only profiles therefore still rely on
Claude Code refreshing the dir it runs in; because the usage endpoint is
account-scoped, such a profile borrows the rings of another profile on the same
account (same email *and* organization) if one is present, and failing that
says "Token expired — open Claude Code in this profile".

A profile with no token at all keeps saying so rather than borrowing: that is
also what a denied Keychain prompt looks like, and it is worth fixing rather than
hiding.

macOS asks once per item for permission to read it. "Always Allow" stops it
asking again.

## Profiles

A profile is a Claude Code config folder — one logged-in account. Relocating it
with `CLAUDE_CONFIG_DIR` is the only way Claude Code supports more than one, so
that's what discovery looks for: `~/.claude`, anything beside it whose name
starts with `.claude`, and folders you add in Settings. A folder counts when it
contains a `projects` directory.

Pick the menu bar's profile in Settings; each widget picks its own. Every
profile keeps its own cache and its own history file, so one account can never
show another's numbers.

**macOS caveat.** The Keychain item's name is hashed from the *literal*
`CLAUDE_CONFIG_DIR` string you exported — Claude Code does no path resolution, so
`~/.claude-work`, `$HOME/.claude-work` and `/Users/you/.claude-work/` are three
different items. We try the plausible spellings; if yours is unusual the profile
reports `no-token`. Settings shows the name we look for, next to the folder, so
you can check it against:

```sh
security dump-keychain | grep -o '"svce"<blob>="Claude Code[^"]*"' | sort -u
```

Tokens and cost still work either way, since those come from transcripts on disk.

## Settings

Five tabs, because macOS settings are conventionally tabbed and there are now
enough of them to warrant it.

| Tab | What's there |
|---|---|
| General | Refresh interval (1–10 minutes), open at login, global shortcut, export and copy, User-Agent |
| Display | Menu bar as text or a drawn ring, which window it tracks, the text style, and the amber/red thresholds |
| Alerts | Threshold notifications, daily and monthly budget targets |
| Profiles | Account picker, added folders, rescan |
| Updates | Version, check and install, Homebrew resync |

A few of these are worth a sentence each.

**Refresh interval.** Every profile is polled on this schedule and each poll is
what refreshes the widgets. Longer intervals also stretch what "outdated" means:
numbers are called stale after three polls, not after a fixed three minutes, so
picking ten minutes doesn't label one-poll-old figures as old.

**Menu bar ring.** Menu bar items are normally rendered as template images, which
is why the text label signals critical with a `!` rather than red. The ring is
drawn and its colour kept deliberately — it's opt-in, and text stays the default,
because monochrome is the convention here.

**Notifications** fire once per upward crossing of your amber and red
thresholds, for the selected profile only, and re-arm when the window resets.
Budget targets are their own opt-in: setting one turns its alert on, since a
target you can see a bar for but never hear about is a decoration.

**Global shortcut** is four presets rather than a key recorder. It uses Carbon's
hotkey API, so it needs no Accessibility permission. If another app already owns
the combination, this one silently loses it — pick a different one.

**Export** writes daily totals and the per-model split as CSV, or the whole
snapshot as JSON, depending on the extension you save under.

## Architecture

```
Sources/
  UsageCore/     data layer, no UI — shared by the app, the widget, and the CLI
  SharedViews/   the ring gauge and palette, shared by the app and the widget
  MenuBarApp/    MenuBarExtra, the poller, notifications, settings
  Widget/        AppIntent configuration and the widget families
  UsageCLI/      prints the snapshot; the CI smoke test
```

`swift test` covers `UsageCore` with no Xcode involved. The app and widget
bundle is built by Xcode via XcodeGen, since SPM can't express an app that
embeds an extension. Both build systems compile `Sources/UsageCore` directly —
there's no framework target to embed and sign.

Getting data to the widget is the fiddly part, and worth writing down:

- **The widget extension must be sandboxed.** macOS never registers an
  unsandboxed app extension, so it silently never appears in the widget gallery.
  That rules out reading `~/.claude` from the widget.
- **App Groups are the textbook answer and don't work here.** They're a
  provisioning-profile capability, so with ad-hoc signing and no team
  `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil.
- **The host app isn't sandboxed**, so it writes directly into the widget's own
  container at `~/Library/Containers/…widget/Data/Library/Application Support/`.
  Inside the sandbox the widget reads exactly that as its Application Support —
  no entitlement, no App Group, no paid account.

The host only writes there once macOS has created the container; materializing
one by hand leaves it without its container metadata, which can stop the
extension launching at all. So a freshly added widget shows a placeholder until
the next poll — at most one refresh interval, a minute by default.

Each placed widget also carries a **Refresh** setting, and it is worth being
plain about what it does: it changes how often that widget re-reads the file,
and nothing else. Only the host app fetches, so when the app isn't running there
is nothing newer on disk to find. "Follow app" — the default — takes the
interval from the snapshot the app publishes. Everything is floored at five
minutes because WidgetKit budgets macOS reloads and quietly ignores anything
tighter.

## Developing without a Mac

Swift doesn't build on Windows, so CI is the compiler and the display:

```sh
gh run download <run-id> -n snapshots -D snapshots
```

`Tests/SnapshotTests` renders every view — widget families, project scope, the
menu popover — across light and dark and every data state, and CI uploads the
PNGs. The gallery images above come from the same pipeline, so they can't drift
from the UI; they *are* the UI, with a backdrop and a shadow.

### Unverified

What the snapshot loop cannot prove, and needs a pass on real hardware:

- The widget loads and appears in the widget gallery. It didn't at first — the
  extension shipped unsandboxed and macOS never registered it. `build.sh` now
  reports registration; if it says nothing is registered, `killall chronod`
  forces a rescan.
- The Keychain consent prompt behaves, and the token actually reads.
- "Open at login" sticks — `SMAppService` needs a properly signed app.
- The popover's Refresh / Settings / Quit buttons. `ImageRenderer` draws
  interactive controls as unavailable, so they show as prohibition badges in
  every snapshot. Layout around them is real; the buttons themselves aren't.
- The Settings window. `Form` with `.formStyle(.grouped)` is NSTableView-backed
  and renders empty detached, so there are deliberately no settings snapshots
  rather than blank ones posing as coverage. That now covers five tabs.
- **Placed widgets survive the new `Refresh` parameter.** Adding a parameter
  should be the safe kind of change where changing a *type* was not — 0.3 and
  0.3.2 both killed placed widgets and there is no supported migration — but the
  only proof is a widget placed before the upgrade still rendering after it.
- **Notification authorization on an ad-hoc-signed build**, same class of problem
  as "Open at login" above. A denial is silent by design, so "no notifications"
  and "not authorized" look identical from here.
- **The drawn menu bar ring**: a non-template `NSImage` in a `MenuBarExtra`
  label, against light, dark, and tinted menu bars.
- **The global shortcut**, both halves — Carbon registering without a permission
  prompt, and the status-item lookup actually opening the popover. It fails
  closed: if the button isn't found, nothing happens.
- **Opus and Sonnet weekly windows.** The field names are documented by other
  trackers, not by Anthropic. `swift run usage-cli` prints them when the endpoint
  returns them, which is the check.

## Try the data layer

Runs on any Mac with a Swift toolchain, no Xcode project needed:

```sh
swift run usage-cli              # human-readable summary
swift run usage-cli --profiles   # list discovered profiles
swift run usage-cli --json       # exactly what the widget will render
swift run usage-cli --write      # write the snapshot files to disk
```

## Cost accuracy

Costs are computed from token counts, because current Claude Code transcripts no
longer record a `costUSD` field. Cache writes are billed by TTL — 1.25x input
for the 5-minute cache and 2x for the 1-hour cache — and Claude Code writes
almost exclusively 1-hour entries. Collapsing both into the 5-minute rate (which
the Stream Deck plugin did before v1.7) understates the real figure
substantially.

On Pro/Max plans this is notional equivalent API spend, not money you were
charged. Rates live in `Sources/UsageCore/Pricing.swift`; edit them when
Anthropic changes pricing.

Scanning is incremental — per-file byte offsets, so each poll re-reads only what
was appended rather than the multiple gigabytes an active `~/.claude/projects`
accumulates. That is what makes a one-minute default affordable, and why a
longer interval saves less than you would think.

## History and projects

Daily totals are kept in `~/Library/Application Support/ClaudeUsage/history.json`.
They have to be recorded rather than recomputed: the scanner only reads the last
7 days of transcripts, and Claude Code prunes them after about a month. On first
launch a one-off backfill reads the whole archive so the chart starts populated
instead of filling in over a week.

Project names come from each entry's `cwd`. The directory name under
`~/.claude/projects` is a slug that flattens `/`, `\` and `_` all to `-`, so it
can't be reversed into a real name.

## Releasing

```sh
git tag v0.3.0 && git push origin v0.3.0
```

That builds, stamps the version, makes the DMG, publishes a release, and updates
the cask in [saeedkolivand/homebrew-tap](https://github.com/saeedkolivand/homebrew-tap).
The tap update needs a `TAP_TOKEN` repository secret — a fine-grained PAT with
Contents: read/write on `homebrew-tap`. Without it the release still publishes
and the step is skipped.

## License

MIT
