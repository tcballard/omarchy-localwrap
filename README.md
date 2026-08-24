# LocalWrap for Omarchy

A bar-widget cockpit for local development projects on
[Omarchy](https://omarchy.org)'s Quattro shell. It reads the
version-controlled LocalWrap workspace manifest a repository commits
(`.localwrap/workspace.json`, or `localwrap.json` at the repository root) and
lets you start, monitor, stop, and open the loopback apps the repository
describes — without terminal juggling.

This is the Linux companion to the
[LocalWrap macOS app](https://github.com/tcballard/LocalWrap): both speak the
same [workspace manifest v1](https://github.com/tcballard/LocalWrap/blob/main/Documentation/workspace-manifest-v1.md)
contract and share the same safety model. It is a re-implementation for the
Quattro plugin runtime, not a port; the macOS app's deeper features (Doctor,
crash-safe ownership ledger, live preview, support reports) remain app-only.

Status: **experimental**, version 0.2.0.

## What it does

- Bar widget shows `LW ready/total` for every configured project (`!` marks
  projects that need attention). Click it to open the cockpit panel.
- The panel lists each configured repository's projects with status, command,
  and URL. Reading a repository never runs anything: **Start** is the only
  execution action.
- Start launches the manifest command directly (no shell), with `PORT` set,
  in the project's directory; readiness is confirmed by probing the project's
  health-check URL every 500 ms for up to 30 s (HEAD request, 1 s budget, any
  HTTP status below 500 counts as ready) — the same contract as the app.
- Before starting, the plugin verifies the executable exists and probes the
  health URL; if something already responds, it reports a conflict instead of
  starting a second copy.
- **Open** hands the project's validated loopback URL to your default
  browser. **Stop** terminates the process the plugin started.
- Projects with `dependsOn` stay gated until their dependencies are Ready.
- Manifest `workspaces` get **Start all** / **Stop all**: starting brings up
  the grouping's members plus their transitive dependencies in dependency
  order, waiting for each dependency to become Ready; stopping works in
  reverse. A member that fails, conflicts, or stalls halts the run with a
  visible reason.
- Configuration and manifest edits are picked up automatically (mtime
  polling every 5 s); a reload never touches running processes. **Rescan**
  remains for immediate refresh.
- Opt-in desktop notifications (`notify-send`) on Ready, Failed, port
  conflict, and not-ready-in-time transitions — status only, never command
  output.
- Opt-in auto-open on Ready: only when your configuration enables
  `openOnReady` *and* the project's manifest sets `openOnReady`.
- A running process whose manifest entry disappears after a rescan stays
  listed until you stop it — the plugin never loses track of a process it
  started.

## Requirements

- Omarchy with the Quattro shell (plugin `schemaVersion` 1).
- `curl` (readiness probes), `which`, `test`, and `stat` (coreutils) —
  present on any Omarchy install.
- `notify-send` (libnotify), only if you enable notifications.
- The runtimes your manifests use (`npm`, `pnpm`, `bun`, …) on `PATH`.

## Install

```sh
omarchy plugin add https://github.com/tcballard/omarchy-localwrap.git --enable
```

Place the widget where you want it:

```sh
omarchy bar move io.github.tcballard.localwrap --section right
```

## Configure

Create `~/.config/localwrap/repositories.json` listing the repositories whose
manifests you trust:

```json
{
  "repositories": [
    "~/src/storefront",
    "/home/you/src/blog"
  ],
  "notifications": false,
  "openOnReady": false
}
```

Both optional flags default to off. `notifications` sends desktop
notifications on runtime transitions. `openOnReady` lets a project open in
your browser when it becomes ready — and even then only for projects whose
manifest also sets `"openOnReady": true`, so both you and the manifest
author must opt in.

Each repository needs a LocalWrap workspace manifest, for example
`.localwrap/workspace.json`:

```json
{
  "localwrap": 1,
  "projects": [
    {
      "id": "web",
      "command": "pnpm dev",
      "path": "apps/web",
      "port": 3000,
      "healthCheck": { "path": "/health" }
    }
  ]
}
```

See the [manifest v1 guide](https://github.com/tcballard/LocalWrap/blob/main/Documentation/workspace-manifest-v1.md)
and [JSON Schema](https://github.com/tcballard/LocalWrap/blob/main/Documentation/schema/workspace-manifest-v1.schema.json)
for every field. Edits to either file are picked up automatically within a
few seconds; **Rescan** in the panel forces an immediate refresh.

## Usage

Click the `LW` widget to open the cockpit. Each project row shows a status
dot (gray stopped, yellow starting, green ready, orange running-but-not-ready,
red failed or port conflict), the exact command it will run, and its URL.
Start, Stop, and Open act on that row alone; Escape closes the panel.

Below a repository's projects, its manifest `workspaces` appear with their
computed start order (`db → api → web`) and a ready count. **Start all**
walks that order, starting each project once its dependencies are Ready;
**Stop all** stops the grouping in reverse. If a member fails on the way up,
the run halts and the row says why.

## Security model

Omarchy plugins run unsandboxed inside the shared shell process, so this
plugin keeps LocalWrap's fail-closed rules:

- Manifest commands are restricted to the v1 executable allowlist
  (`npm npx yarn pnpm node bun python python3 deno`), rejected if they contain
  shell metacharacters, and launched directly — never through a shell.
- URLs (project and health check) must be loopback `http(s)` on
  `localhost`, `127.0.0.1`, or `[::1]` with an explicit port from 1000–65535;
  only validated URLs are probed or opened.
- Unknown manifest fields are blockers, which refuses secret-bearing
  extensions (`environment`, `secrets`, `tokens`, …) exactly like the app.
- Nothing autostarts. Reading configuration and manifests is passive;
  `autostart` in a manifest is parsed but deliberately not acted on.
- The only external commands the plugin runs are `cat` (read config and
  manifests), `which` (confirm an executable exists), `test -d` (confirm the
  project directory exists), `curl` (loopback readiness probes), `stat`
  (poll config/manifest mtimes), `notify-send` (only when notifications are
  enabled), and the reviewed project commands you explicitly start. All are
  invoked with fixed argument lists, never through a shell.
- Process output is kept only in memory (a bounded tail shown on failure)
  and never written to disk.

## Lifecycle and limitations

- Started processes are children of the Omarchy shell. Disabling or removing
  the plugin, or restarting the shell, terminates them. Stop signals the
  direct child process; runners like `npm` forward termination to their
  children.
- A project that is running but not ready within 30 s is marked
  "Running, not ready" and left running for you to inspect or stop.
- A halted workspace run (a member failed, conflicted, stalled, or left the
  manifest) stays halted with its reason until you press **Start all** again;
  automatic reloads never restart or stop anything on their own.
- Manifest path containment is enforced lexically (`..` may not escape the
  repository); the macOS app additionally resolves symlinks on disk.
- If the bar instantiates widgets per monitor, each instance manages its own
  processes; the pre-start conflict probe prevents double-starting the same
  port.

## Development

Work in a user-owned copy, per the
[plugin development guide](https://omarchyplugins.com/develop.html). From a
checkout of this repository, `./install.sh` copies the payload into
`~/.config/omarchy/plugins/io.github.tcballard.localwrap/` (files only, no
symlinks; it never enables or starts anything).

Pure logic lives in `Model.js`, shared verbatim between the QML entry points
and the node test suite:

```sh
node --test tests/model.test.js
```

Validate the installed folder on an Omarchy machine:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/io.github.tcballard.localwrap
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/io.github.tcballard.localwrap/BarWidget.qml \
  ~/.config/omarchy/plugins/io.github.tcballard.localwrap/Panel.qml
```

## Troubleshooting

- **Widget missing after install** — run `omarchy-shell shell rescanPlugins`,
  then `omarchy plugin list --json` to confirm discovery and enablement.
- **Panel shows "No repositories configured"** — create
  `~/.config/localwrap/repositories.json` as above, then Rescan.
- **Repository shows blockers** — the manifest violates the v1 contract; the
  diagnostics name the field. The macOS app's `LocalWrap validate-manifest`
  prints the same class of findings.
- **Start is dimmed with "Waiting on …"** — a `dependsOn` project is not
  Ready yet; start dependencies first.
- **Component fails to load** — inspect
  `qs log -p "$OMARCHY_PATH/shell" --tail 100` for QML errors.

## Remove

```sh
omarchy plugin remove io.github.tcballard.localwrap
```

Removal stops anything the plugin started. Your repositories, manifests, and
`~/.config/localwrap/repositories.json` are untouched.

## Roadmap

- Submission to the [Omarchy plugin marketplace](https://omarchyplugins.com).
- Richer per-project diagnostics (closer to the macOS app's Project Doctor).

## License

Apache-2.0, same as LocalWrap. See [LICENSE](LICENSE).
