# PortBar

A macOS **menu-bar list of every localhost port that's currently in use**, and a
one-click way to stop what's holding one. Native `NSMenu`, no window. Built for the case where several AI
agents have each started a dev server and you've lost track of which is which.

## Build & run

```
xcodebuild -project PortBar.xcodeproj -scheme PortBar -configuration Debug build
```

Menu-bar accessory app (`LSUIElement`) — no Dock icon, no main window.

**Deployment target: `MACOSX_DEPLOYMENT_TARGET = 15.0` / Swift 5 — chosen, not
default.** Xcode stamped the SDK version (26.5), which shuts out every user
below it. 15.0 is the floor `@Observable` and `.pointerStyle` need.

**The app is NOT sandboxed (`ENABLE_APP_SANDBOX = NO`) and that is
load-bearing.** The sandbox denies both halves of the app's job: `proc_info` on
processes we didn't spawn (what `lsof` needs — it returns an empty table, not an
error) and `kill()` on anything we didn't launch (`EPERM`). Consequence: PortBar
can never ship on the Mac App Store. Don't "fix" the sandbox setting.

## Architecture

No dependencies. **AppKit, not SwiftUI** — there is no window and no view in the
running app.

- **PortBarApp** — `@main`, whose only job is `@NSApplicationDelegateAdaptor`.
  Its `Settings { EmptyView() }` scene exists purely to satisfy `App`.
- **AppDelegate** (`@MainActor`) — owns the `NSStatusItem` and the `NSMenu`, and
  is the `NSMenuDelegate`. Every menu action is an `@objc` selector here.
- **PortMenu** (`@MainActor`) — builds the menu items from the current port list.
- **PortMonitor** (`@MainActor`) — the data: entries, the poll, and the actions
  (stop / open / logs / copy / reveal).
- **PortScanner** (`nonisolated`, blocking) — shells out to `lsof` and `ps` and
  returns `[PortEntry]`.
- **ProjectName** (`nonisolated`) — what to *call* a row: walks up from the cwd
  reading `package.json`/`Cargo.toml`/`go.mod`/`pyproject.toml`/`.git`.
- **DockerPorts** (`actor`) — cached host-port → container-name map, plus the
  one place that knows where the `docker` CLI lives.
- **LogViewer** (`nonisolated`) — turns a `LogSource` into something on screen.
- **BrowserOpener** (`nonisolated`) — opens `http://localhost:<port>`, reusing a
  tab that already has that port open.
- **Shell** (`nonisolated`) — the one subprocess runner plus AppleScript/shell
  quoting.

## How the scan works

Three process spawns, **~90ms total** (34 + 26 + 31, measured):

1. `lsof -nP -iTCP -sTCP:LISTEN -F pcn` — the listening sockets.
2. `ps -axo pid=,command=` — full argv, for the tooltip and Copy Command.
3. `lsof -a -d cwd,1 -p <all pids at once> -F pftn` — working directories *and*
   stdout, which is what decides each row's `LogSource`.

**Use `lsof`'s `-F` machine-readable mode, never the columnar default** — that
one truncates the command name to 9 characters, turning every interesting
process into `Code\x20H` or `com.dock`. In `-F` output each line is one field
tagged by its first character (`p`=pid, `c`=command, `n`=name/address).

**Batch the cwd lookup.** Asking `lsof` for one PID's cwd at a time is a process
spawn per port, on a timer. One call with a comma-joined PID list is the same
~15ms whether it's 3 PIDs or 40.

**Drain the pipe before `waitUntilExit()`.** `lsof` output exceeds the 64K pipe
buffer on a busy machine and the wait would deadlock against it.

**One row per port.** `lsof` reports the same port once per file descriptor and
once per address family, and occasionally under two PIDs (`SO_REUSEPORT`); the
scanner collapses these before the UI sees them (lowest PID wins so the row
doesn't flip between scans; the all-interfaces flag is the union). `PortEntry.id`
is the port; duplicates used to crash SwiftUI's `ForEach` and would now produce
two identical menu rows.

See **Refreshing** above for when this runs: synchronously on menu open, and on
a slow background poll for the count.

## The dev/system filter

34 things listen on TCP on a normal Mac and ~6 of them are yours. Default view
shows only the dev ones; a footer toggle reveals the rest, **with the hidden
count on its label** so the filter never looks like it's concealing something
silently.

`PortEntry.isDev` — two positive signals, one override:

- a recognised runtime or dev daemon (`devCommands`: node/bun/python/docker/
  postgres/ollama/…), which is enough on its own because plenty of them run
  with no useful cwd;
- **or a working directory under `$HOME`** — this is the part that makes it work
  for tools we've never heard of, because anything an agent starts from a repo
  has one;
- **`neverDev` and any command containing "helper" beat the cwd signal.** Editor
  and browser helpers inherit the project's cwd, so without this the list fills
  with a dozen `Code Helper (Plugin)` rows on internal plumbing ports. This was
  the single biggest source of noise — verified against a live machine.

`projectName` (the row's primary label) is deliberately `nil` for support
plumbing — the home directory itself, anything under `~/Library`, and any path
with a dot-directory component. Otherwise Docker reads as project "Data"
(`~/Library/Containers/…/Data`) and a Gradle daemon as "8.13"
(`~/.gradle/daemon/8.13`). Falling back to the command name is more honest.

## Naming a row

The row's primary label is `PortEntry.projectName`, and it is **stored, not
computed** — deriving it reads files, which a view must never do. `PortScanner`
fills it in, memoised per cwd (several ports share a process, several processes
share a directory).

**`basename(cwd)` is not enough, and the failure is concrete.** In a monorepo a
dev server started in `apps/web` is called "web", and one machine can easily
hold *three* projects that would all show exactly that. `ProjectName.detect` walks up from
the cwd reading `package.json` `name`, `Cargo.toml`, `pyproject.toml`
(`[project]` or `[tool.poetry]`), `go.mod`'s last path component, then a `.git`
folder's own name — which yields `@acme/web`, `@northwind/web`, `@contoso/web`.
Verified against ten real paths, including that a plain repo root and a non-home
path such as `/opt/homebrew/var/postgres` are left unchanged.

**Manifests are only read under `$HOME`, and `$HOME` itself is never a project
root** — plenty of dotfile setups leave a `.git` or a `package.json` in it, and
a process running from `/Applications` has no project to find.

**Support plumbing still falls through to `nil`** (→ the command name), because
its leaf is actively misleading: Docker's `~/Library/Containers/…/Data` reads as
"Data" and a Gradle daemon's `~/.gradle/daemon/8.13` as "8.13". The rule is
`$HOME` itself, anything under `~/Library`, and any path with a dot-directory
component.

**Docker rows are named from the daemon, because nothing else can name them.**
Every container's published port is held by the same `com.docker.backend` proxy,
so the port is the only handle on which container owns it — `lsof` and `ps` are
no help. `PortMonitor.refresh` asks the `DockerPorts` actor, which caches the
`docker ps` map for 30s. **`docker ps` costs about the same as the whole port
scan (~46ms measured), not an order of magnitude more** — an earlier version of
this file claimed otherwise. It's cached because container names barely change,
not because it's slow. A second, 3s floor stops a published port the daemon
doesn't recognise from re-running `docker ps` on every single scan.

`DockerPorts` is an **actor** because scans overlap: the poll loop and a
stop-triggered refresh both call in.

## Why a native NSMenu

The UI was a SwiftUI `MenuBarExtra(.window)` panel and is now a real `NSMenu`
handed to the status item. Don't undo this lightly: **hover-opens-submenu,
arrow-key navigation, type-to-select, edge flipping, click-and-drag selection
and accessibility are all AppKit's.** The panel hand-rolled hover highlighting,
its own dashed separators, an exact pixel row height and a `⋯` button with a
hand-tuned hit target — and *still* couldn't open a submenu on hover, because an
open `NSMenu` runs a modal tracking loop that starves every other row of hover
events.

What the panel could do that a menu can't, and where each went:

| Panel | Menu |
| --- | --- |
| Two-line row (name + `pid`, `0.0.0.0`) | One plain line; the rest is the submenu's disabled header |
| Tabular-digit port column, aligned | Port leads a plain title — see below |
| Toggle switch for the filter | `NSMenuItem.state` checkmark |
| Spinner while a stop is in flight | Nothing: picking an item closes the menu |
| Click the row to open a browser | Row has a submenu, so it isn't clickable |

That last one is a real loss, and it's the trade for hover submenus. It's a wash
on clicks: *Open in Browser* used to be 1 click and everything else 2 (open
`⋯`, pick); now everything is 1 hover + 1 click.

**Titles are plain strings, never `attributedTitle` — on anything pickable.**
An attributed title with explicit colours does **not** invert when AppKit
highlights the row, so a two-tone "port in grey, name in white" line becomes
dark text on the accent colour the instant you hover it. Hence
`3000 · northwind-polls-app` as one plain line, port first so there's still a
column edge on the left. This is why the panel-era work on `.monospacedDigit()`
and a 38pt port column is gone.

**The exception is a *disabled* item, and the submenu's footer facts use it.**
AppKit never highlights a disabled item, so the colour can't fail to invert, and
an attributed title is the only way to get a tab stop — which is what puts the
footer's labels and values in two columns. Two things come with it: the colour
must be a dynamic system one (`NSColor.disabledControlTextColor`), because
AppKit draws an attributed title exactly as given and won't grey it for you; and
so must the font (`NSFont.menuFont(ofSize: 0)`), or the item renders in a
default that doesn't match its neighbours. **`NSMenu` does honour `tabStops` —
verified**: moving a stop from 60pt to 140pt widened the menu's own `size` by
exactly the 80pt difference.

**`menu.autoenablesItems = false` on every menu we build.** AppKit's
auto-enabling would re-enable the disabled *No Logs Available* item and each
submenu's detail header. The cost is that *every* item needs `isEnabled` set
explicitly.

**Menu items carry their row on `representedObject`.** That's how a menu passes
context without closures: one `@objc` selector per action, each pulling the
`PortEntry` back out of the sender.

**`NSImage(named:)` returns a shared instance** — resizing it resizes every other
use of that asset. `PortMenu.icon` copies before setting `size`.

## Refreshing

**The menu rescans synchronously in `menuNeedsUpdate`, blocking the main
thread.** That's the canonical pattern for a dynamic menu, and it means nothing
has to keep a live view in sync — there is no view. A scan measures **~90ms**;
blocking that long on a user-initiated menu open is the right trade, because a
menu showing a stale port list is worse than one that takes 90ms to appear. It
is also exactly why the background poll does *not* use this path. A 1s floor
absorbs reopens.

**The background poll exists only for the menu-bar count**, so it runs at 15s
(~0.6% of a core). It's also the only thing that refreshes Docker names:
`DockerPorts` is an `actor` and can't be read without awaiting, so a brand-new
container shows as `com.docker.backend` until the next tick.

**Don't mutate the menu while it's open.** Rebuilding on open is safe; adding
and removing items from a menu AppKit is currently tracking is not.

**A toggle that changes the menu's contents must re-open the menu.** AppKit
dismisses a menu the instant an item is picked, so *Show System Ports* and
*Launch at Login* would otherwise take effect only the next time you opened it —
you'd click and see nothing happen. `AppDelegate.reopenMenu` calls
`statusItem.button?.performClick(nil)` on the next run-loop turn (deferred so the
current menu has finished dismissing); `menuNeedsUpdate` then rebuilds with the
new setting. This is the only lever available: an `NSMenuItem` cannot decline to
dismiss, and rebuilding in place is the unsafe thing above. The alternative —
an `NSMenuItem.view` with a custom `NSView`, which *can* swallow a click without
dismissing — costs the native checkmark, highlight and accessibility.

## UI/UX principles (established with the user — keep consistent)

**Each row leads with a monochrome brand glyph** — Node hexagon, Docker whale,
Android bugdroid, Postgres elephant — 11pt template images, so AppKit tints them
like an SF Symbol and they follow the highlight. A whale is read faster than any
word. The glyphs are [Simple Icons](https://simpleicons.org) (CC0), one
single-path 24×24 SVG each, in `Assets.xcassets/TechIcons` with vector data
preserved. The logos remain their owners' trademarks; using them to identify a
technology is the convention every editor's file-icon theme relies on.
`PortEntry.iconName` resolves in two stages, and the order is the whole point.

**11pt, not AppKit's usual 16 for a menu image, and deliberately smaller than
the 13pt menu text.** These are solid filled marks where an SF Symbol is a
stroked outline, so at 16 they outweighed the text and the eye ran *down* the
icon column instead of across the row. The glyphs identify a row; they don't
label it. Three rounds of shrinking got here — 16, 14, 12, 11.

**The glyphs are left exactly as Simple Icons ships them — don't rescale
them.** Simple Icons normalises by *bounding box*, so every glyph touches 24 in
at least one dimension, and how much of that square is actually filled varies 8×
— from `mysql` at 62 units² of ink to `strapi` at 482, median 202. That shows:
Vite is a solid bolt at 1.34× the median, and beside Astro (0.97×), Android
(1.04×) and Docker (1.08×) it read as oversized and stretched. It was reported
as exactly that.

It was tried, and **rejected**: every glyph's `viewBox` widened about its centre
by `clamp(sqrt(median / area), 0.86, 1)`, which evens the weight without
touching a path. It worked, and the user still said no — **the artwork is
authentic and stays that way**. Vite's path matches the official mark on
vite.dev exactly, nothing in `PortMenu.icon` distorts it (the canvas is square
and we draw into a square), and a logo quietly scaled to 86% is no longer the
logo. The answer to "one glyph looks heavy" is a smaller icon column, not
edited assets.

**`lsof` reports the *interpreter*, never the framework.** A Next, Vite, Astro,
Nuxt, Django or Rails server is all just `node`/`python3`/`ruby` to it — verified
against a live machine, where an Astro dev server reports `node`. So for the
runtimes in `interpreters`, `frameworkIcon` matches the **argv** against
distinctive path fragments first (`/next/dist`, `astro@`, `@sveltejs`,
`manage.py`, …). Before this existed, the three most common dev servers on a Mac
all rendered as the same generic Node hexagon, and the `vite`/`astro`/`expo`
entries in the command map were dead code that could never fire.

`frameworkMarkers` is **ordered, and specific must beat general**: `vitest`
before `vite`, because one contains the other; and a Next project's argv mentions
webpack and react. Match on package *paths* (`/.bin/next`, `@angular`) rather
than bare words, which appear in any long path. Unknown processes get SF
`terminal` rather than a gap, because a column with holes reads as missing data. Docker
rows get the whale regardless of the container's contents — the container *name*
already says what's inside; mapping `{{.Image}}` to a glyph is a possible
refinement.

**Long names are middle-truncated to a measured width** (`MenuText.rowLabelWidth`,
134pt for the label after the `1234 · ` prefix), never tail-truncated.
The names that need shortening come from monorepos and compose files, and those
share long prefixes while differing at the end: tail-truncating
`northwind-customer-dashboard-db` and `…-redis` renders both as
`northwind-customer-dashbo…`, throwing away the only part that identifies them.
Middle truncation keeps them as `zkpassp…oard-db` and `zkpassp…rd-redis`. The
budget is a **pixel width, not a character count** — it lives in `MenuText`
because only AppKit can measure the menu font.

It is tuned to **fill** the menu, not to set its width. AppKit reserves a shared
right-hand column across every item for key equivalents (`⌘Q` on *Quit
PortBar*), and the submenu arrows sit in that column — which left a visible gap
between a row's text and its arrow. 134pt spends that slack: the widest row is
~172pt, against a menu already at least as wide as *Show System Ports (18)*
(144pt) plus the reserved column. Tune this by *rendered characters* rather than
by eye — measure what a candidate actually produces. Past roughly here it widens the menu instead
of filling it — 145pt would fit `northwind-mobile-app` (136pt) whole, but takes the row
back to 185pt, which was too wide.

**Rows have no `toolTip` at all.** It carried `commandLine` first (so hovering
anything popped an absolute path halfway across the screen), then the full label
on truncated rows — still an unasked-for panel appearing over the menu. The full
label now lives at the **bottom of the submenu**, shown only when the row
abbreviated it, which means nothing the list shortens is hidden behind a hover.

**Flat, never split into Ports/Docker sections** — but the *order* is the
user's, via **Sort By**. (Open Ports sections them; a section means looking in
two places.)

- **Port Number** (default) — the order `PortScanner` already returns, and the
  only one you can scan when you know the number you want.
- **Technology** — groups rows that share a glyph, which is the question this
  app was built for: *what have I got running?* Several agents each start a
  server, and seeing both Vite rows together answers that faster than any
  number. `PortEntry.technologyKey` is `(0, iconName)` for anything with a
  glyph and `(1, commandKey)` for anything without, so the unrecognised rows
  group by their own name and land last rather than pooling a Postgres and a
  Java daemon under one meaningless heading. **Port breaks the tie**, so a
  group's rows keep their number order and nothing shuffles between scans.

**Two checkmarked choices, not an item that cycles.** Two orders is few enough
to cycle, but a cycling item can only name one of them, so it can't say which
you're on without spelling out both. Picking one **reopens the menu** for the
same reason the toggles do — see *Refreshing* — since a reordered list you can't
see is indistinguishable from a click that did nothing.

They live as a **section inside *Settings*, not a submenu of it.** Nesting would
put a routine choice three levels deep, and `.sectionHeader` names the group
just as well for nothing.

**Every submenu is the same width** (`MenuText.submenuWidth`, 238pt). Constant
is the part that matters, not the number. Before this, width followed whatever
the longest detail line happened to be, so the submenu resized from row to row —
and near the right edge of the screen a wide one didn't fit on the right, so
AppKit **flipped it to the left of the menu** while a narrow one stayed put.
That flip is what made the position look random. The width is set with
`NSMenu.minimumWidth`, which is a floor, so anything that doesn't fit must be
wrapped or it forces the menu wider again.

It was 198pt, narrower than the main menu's ~229pt, and that was treated as a
principle. It isn't one — a submenu wider than its parent is ordinary on macOS,
and the 150pt text budget behind it was actively costing something: it cut
a 23-character project name (150.9pt) in half **by nine tenths of a point**,
leaving a four-character orphan line that read as a rendering bug. The floor is
190pt now for that reason.

The width is **derived, never hardcoded**, from three constraints: the longest
action title (an action that wrapped would be absurd); the widest footer *fact*,
measured from the value column it starts at, because a wrapped
`com.docker.backend` reads as damage where a wrapped project name reads as a
long name; and the comfort floor above, which exists for the name heading.
Keep `MenuText`'s lists in step with what `PortMenu` actually emits — including
`detailLabels`, which sets the value column and so can overrun its own values if
a longer label is added in `PortEntry` and not here. `submenuChrome` (48pt) is
AppKit's own margin around a title, measured empirically: **err high**, because
erring low lets content force the menu wider and reintroduces the bug.

**Every footer fact is named, in two columns.** `PortEntry.detailFacts` returns
`(label, value)` — *Process* / `node`, *PID* / `1621`, *Binding* / `0.0.0.0` —
and `PortMenu.factItems` draws each with a tab stop at `MenuText`'s
`detailValueColumn`, so the labels form one column and the values another.

They were bare values on their own lines, and the user couldn't tell which was
which: a row read `northwind-mobile-app`, `node`, `pid 1621`, where only the
pid announced what it was. **A run of unlabelled grey words is a list of answers
with the questions missing.** The column is derived from the widest label rather
than picked, so rewording a label can't quietly break the alignment.

**The full project name is the block's heading, not a fact.** It gets the whole
width and no label — it's the same text the row already shows, and labelling it
would cost the value column the 60pt that lets an ordinary name fit on one line.
It appears **only when the row abbreviated it**, which is what lets rows carry no
tooltip at all: nothing the list shortens is hidden behind a hover.

**Values are wrapped, not truncated** (`MenuText.wrapped`), because the submenu
is the one place the full name is shown and abbreviating it twice would defeat
the point. Breaks land at spaces and at the separators project names use (`-`,
`_`, `/`, `.`), never mid-word unless a single run is itself too long. A
continuation line is passed an **empty label**, and `headIndent` keeps it in the
value column — so a wrapped name reads as one field rather than as another
nameless fact. Watch the whitespace: an early version trimmed both ends of a
token when starting a new line, which ate the trailing space of `"pid "` and
rendered `pid36878`. Trim *leading* only when starting a line, *trailing* only
when ending one.

A fact is one line, never joined: `com.docker.backend · pid 36878 · 0.0.0.0`
together is the widest thing in the submenu and forces a mid-word wrap.

**The submenu opens with an action, and ends with reference.** The first item is
*Open in Browser* (or *Copy Address*); the `command · pid · 0.0.0.0` detail and
the full label are disabled lines after the last separator. The detail used to
be *first*, so every submenu began with a dead row that swallowed the keyboard's
first Down and read as a bug. Anything you can't pick belongs at the bottom.

**The submenu is short, and every item says what it does.** *Copy Command* (the
full argv) and *New Terminal Window Here* were cut — the user couldn't tell what
either meant, and the argv is now the item's `toolTip`. What remains:

- *Open in Browser* / *Copy URL* — **or**, for a row that isn't a web service,
  a single *Copy Address* that puts `localhost:5432` on the clipboard (what
  you'd paste into a database client).
- *View Logs* — disabled when the stream can't be reached.
- *Open in Terminal* — a **new** shell in the project folder, when there's a
  folder. Not "show me the logs"; see below.
- *Reveal in Finder*, when there's a folder — shortened from "Reveal Folder
  in Finder", which was the single widest label and so set the submenu width.
- *Stop* / *Force Stop*.

**A database row does not offer a browser.** `PortEntry.isLikelyWeb` is a
known-list heuristic — process names (`postgres`, `redis-server`, `adb`, …) and
well-known non-HTTP ports (5432, 6379, 1025, …), the latter mostly for Docker
rows where the process is the shared proxy and tells us nothing. Unknown means
web, because an unrecognised dev server is the common case and a wrong "not web"
is the more annoying mistake. A real answer needs an HTTP probe, which is
deliberately not in the poll loop.

**The filter's hidden count is on the list's own heading** — `Listening Ports ·
22 hidden` — so it never looks like it's concealing something silently. The rule
is that the number is visible **without interaction**, not that it rides on the
control; when the control moved into *Settings* the number stayed out here. The
heading was carrying no information before, so this cost nothing. It also still
sits on the *Show System Ports* label itself, where it says how many that click
would reveal.

**Everything that isn't a port lives behind one row: *Settings*.** It was four
rows and two separators under a list that is often four rows itself, so half of
what opening PortBar showed you was the app talking about itself. Folding it
took the menu from 248pt to **189pt with the same four ports** — about two rows
given back — and the longer heading doesn't widen it by a single point, both
measured. Nothing in there is touched while you're reading the list: the sort
order and *Launch at Login* are set once, and the system filter is for the rare
"show me everything" moment.

**Quit stays on the top level**, because that is where people look for it, and
there's no separator between it and *Settings*: both are the app talking about
itself, and the one separator above already divides the app from the ports it
found.

**Menu-bar glyph is `network`**, not `cable.connector` — the latter read as a USB
plug. The count beside it uses `monospacedDigitSystemFont`, or the status item's
width jitters and shoves every icon to its right. Alternatives if it ever needs
changing: `point.3.connected.trianglepath.dotted`,
`dot.radiowaves.left.and.right`. There is still no Dock/Finder app icon; as an
`LSUIElement` app it only shows in Finder and Activity Monitor.

## Gotchas (learned the hard way — don't reintroduce)

- **Never let a number reach SwiftUI localization.** This bit us while the UI
  was SwiftUI: `Text("\(entry.port)")` rendered port 14761 as "14 761" and pid
  54469 as "pid 54 469". Plain Swift interpolation into a `String` — what
  `menuTitle` and `detailLine` do now — is *not* affected; only
  `LocalizedStringKey` is. If a SwiftUI view ever returns, use `Text(verbatim:)`.
- **`attributedTitle` colours don't invert on highlight** — see above. Plain
  titles on anything pickable; the footer facts get away with it only because a
  disabled item never highlights, and they must then set their own font *and* a
  dynamic colour, since AppKit draws an attributed title exactly as given.
- **Reading `custom title` on a Terminal tab throws** if none was ever set, so
  every read needs a `try` guard (`LogViewer`).
- **Drain a `Pipe` before `waitUntilExit()`** (`Shell.run`). `lsof` output
  exceeds the 64K buffer on a busy machine and the wait deadlocks against it.

## Behavior notes

- **Stop is SIGTERM; Force Stop is SIGKILL.** `kill()` direct, no subprocess.
  `EPERM` means root-owned and is surfaced as a disabled item next time the menu
  opens, not swallowed.
- **A stop is verified, but not shown.** Picking a menu item closes the menu, so
  there's no row left to dim — the monitor re-scans at 400ms and 2s so the count
  catches up once the socket is actually released. A process that ignored
  SIGTERM simply reappears, which is the cue to use Force Stop. The old panel
  dimmed the row and ran a three-step escalation with a spinner; a menu doesn't
  need it.
- Killing the listening PID of an `npm run dev` tree stops the server but may
  leave the wrapper (`npm`) around. Acceptable for now; process-group kill was
  rejected as too blunt (a VS Code helper's pgid is the whole editor).

## Reusing a browser tab

Clicking a row used to add a tab every time — six localhost tabs had piled up on
one test machine, three of them on port 3000. `BrowserOpener` searches the
**default** browser for a tab already on that port and reveals it, falling back
to `NSWorkspace.open` when there's no match.

**Three scripting dialects**, differing in both hierarchy and verb:

| Browser | Hierarchy | Reveal |
| --- | --- | --- |
| Arc (and Dia) | windows → **spaces** → tabs | `focus` the space, then `select` the tab |
| Safari | windows → tabs | `set current tab of window` |
| Chrome / Brave / Edge / Vivaldi / Opera | windows → tabs | `set active tab index of window` |

**In Arc, `focus` is a *space* command, not a tab one** — the dictionary lists
both under one flat namespace and it's easy to misread. A tab only understands
`select`, and `tell <tab> to focus` fails with `-1708`. Building the reference
from nested loop *variables* also fails; address it by explicit index
(`tab ti of space si of window wi`).

**Firefox exposes no tab scripting at all**, so it — and any unrecognised
browser — falls straight through to `NSWorkspace.open`. Same when the browser
isn't already running: scripting it would *launch* it, which is slower and ruder
than just opening the URL.

**Root tab wins, any path is the consolation prize.** A port often has several
tabs (3000 had `/`, `/debug/articles`, `/inbox`) and the root is what you mean
when you click the row, so the script does one pass tracking the first
any-path hit and returning immediately on a root hit.

**Anchor the prefix match on a trailing slash or exact equality.** A bare
`starts with "http://localhost:3000"` also matches port **30001**.

**The whole search happens inside one Apple Event.** Pulling every tab's URL
into Swift would be one event per tab, and a real Arc window holds seventy-plus.
Each loop body needs a `try`: a loading or blank tab returns `missing value` for
its URL, and comparing that to text raises rather than being false.

**`NSAppleEventsUsageDescription` is set** (as `INFOPLIST_KEY_…`). Automation is
per-target-app TCC, so the user gets one prompt for Terminal and another for
their browser.

## Per-port logs

Implemented. What "logs" means depends entirely on where a process's stdout
points, which `lsof` reports for free during the scan — `-d cwd,1` costs no more
than the `-d cwd` we already needed. `LogSource` has four cases and **the UI
must not pretend they're equally good**:

| `LogSource` | fd 1 | Menu item | Action |
| --- | --- | --- | --- |
| `.file(path)` | `REG` | *View Logs* | `tail -n 200 -f` in a Terminal window |
| `.dockerPort` | any (proxy) | *View Logs* | `docker logs -f --tail 200 <container>` |
| `.terminal(tty)` | `CHR /dev/ttys*` | *View Logs* | **Disabled** |
| `.unavailable` | `/dev/null`, pipes | *View Logs* | **Disabled** |

**The item always says *View Logs*, greyed out when it can't be picked.** It used
to explain itself — *Logs in Another Terminal*, *No Logs Available* — and a
disabled noun phrase in a menu turns out to be ambiguous: the user couldn't tell
whether it was a section header for the item below it, a dead action, or a
status. A single verb phrase, disabled, is the standard macOS idiom (a greyed
*Paste*) and can't be misread. The difference between a PTY and `/dev/null` is
real, but it belongs in this file, not in the menu.

Measured distribution over 7 dev rows on a live machine: 2 files, 1 docker, 3 PTYs,
1 `/dev/null`.

**Logs are a menu item, not a glyph or a hover button.** They were a glyph
twice over: first with two shapes (document = streams output, window = "your
logs are over there"), which meant reading the shape to predict a click; then
one shape for streaming only. Both went when the hover buttons were removed.
The menu item's *name* now carries the distinction — *View Logs* streams,
*Reveal in Terminal* raises the session the server is already running in. That
second one is the only action that can cost you something (closing your dev
server's own window kills it), so it should be chosen by name, never by a glyph.

**Closing a log window does not kill anything — verified, don't "fix" it.**
A disposable container was started on port 56379, streamed with the exact
command PortBar issues, and the window closed: the container stayed `Up` and the
port stayed bound. `docker logs` is a read-only client attached to the log
stream, not to the container's lifecycle. What looks alarming is Terminal's own
close prompt — *"will terminate the running processes: docker"* — where `docker`
is the log client. Expected, harmless, and standard for any `tail -f`.

**The PTY stream is unreachable — this is settled, don't re-litigate it.** The
server writes to the PTY *slave*; the terminal emulator reads the *master*.
Opening the slave puts us on the **input** side, stealing keystrokes rather than
capturing output. Reaching the master fd needs `task_for_pid` on the emulator
(root + entitlements, blocked for a hardened app); DTrace on `write(2)` needs
root and SIP disabled; Endpoint Security needs an Apple-granted entitlement and
carries no write payloads anyway.

**"Reveal in Terminal" was removed — don't bring it back without a mechanism
that works everywhere.** It raised the window already showing a PTY's output,
in three tiers: Terminal.app and iTerm2 expose a `tty` per tab so the exact tab
could be selected, and everything else fell back to walking `ppid` to the owning
`.app` and activating it. That fallback is where it died. A server in VS Code's
integrated terminal resolved correctly to `/Applications/Visual Studio Code.app`
— but VS Code exposes no tty-to-tab mapping, so the best it could do was bring
the window forward *without* selecting the tab, and when VS Code was already
frontmost it looked like the button did nothing at all. Reported by the user as
exactly that. A silent partial failure is worse than no button.

What replaced it is **Open in Terminal**: a new Terminal.app shell in the
project folder. It makes no claim to find the running session, and it works the
same way every time.

**One Terminal window per port, reused.** `do script` with no `in` clause always
opens a *new* window, so clicking the log glyph twice left two windows tailing
the same file. `runInTerminal` is find-or-create: the tab is stamped with a
`PortBar: <port>` **custom title** on creation and found by that title
afterwards — which survives a PortBar restart and doubles as a readable window
title. If the tab is still open but its command has exited (⌃C), the command is
re-run *in that tab*, gated on Terminal's own `busy` flag. Reading
`custom title` **throws** on a tab that never had one set, so every read needs a
`try` guard.

**Logs open in Terminal.app, not in a pane in the app.** Hard reason: a
`MenuBarExtra` window dismisses on focus loss, so an in-panel viewer would
vanish the moment you clicked it — a real one needs a separate `NSWindow`. Soft
reason: Terminal already has scrollback, find, selection and copy, and `tail -f`
is what a developer would have typed anyway.

**`LogViewer` resolves the container fresh on every click**, rather than reading
`DockerPorts`'s cache: the cache exists to label rows cheaply, but someone
opening logs wants the container running *now*. Both go through
`DockerPorts.cliPath`, the one place that knows where the CLI is.

**Commands are double-quoted.** The shell command is single-quoted for `/bin/sh`
(`shellQuoted`) *and* escaped for the AppleScript string literal it's nested in
(`appleScriptQuoted`). Log paths come from `lsof`, so they can contain anything
a filename can.

## Ideas weighed against Open Ports (openports.app) — and rejected

Adopted from it: the **native `NSMenu` with per-row submenus** — which turned
out to be the right architecture, not merely the right look — a **disabled
PID/detail header** inside each submenu, and, still open, the **ignore list**.
Deliberately not adopted:

- **Separate "Open Ports" / "Docker Containers" sections.** PortBar's list is
  flat and sorted by port number, which is the order you scan in when you're
  hunting for a specific one. Sectioning means looking in two places, and
  now that Docker rows carry their container name they no longer need a heading
  to explain themselves.
- **A TCP health indicator** (from [chrisstampar/ports](https://github.com/chrisstampar/ports)).
  `lsof` already reported the socket in `LISTEN` state, so connecting to it
  succeeds essentially by construction — a green dot on every row forever.
  Decoration, not information. The worthwhile version is an HTTP probe.
- **Notifications when a tracked port stops listening** (same source). That
  solves the opposite problem: this app is for having too many servers, not for
  losing them.
- **Manual per-port labels** (same source). Largely superseded by manifest names
  and container names, and it buys an editing UI plus persistence for something
  that should be automatic.

## Not built yet

- **An HTTP identity probe** — a `HEAD` to each port, to label rows by what the
  service actually serves rather than by its cwd's folder name.
- A real in-app log window (`NSWindow`).
- UDP ports, a search field, ignore-lists for specific ports.
