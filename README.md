# LocalWrap for Omarchy

**Your local development workspace, controlled from the Quattro bar.**

LocalWrap is an Omarchy bar widget for developers running multi-service
projects. It reads a repository-owned LocalWrap manifest and gives you one
cockpit to review exact commands, start dependencies in order, watch readiness,
stop complete process groups, and open numeric-loopback apps.

```sh
omarchy plugin add https://github.com/tcballard/omarchy-localwrap.git --enable
```

The QML model and bounded runtime helper have 47 portable regression tests,
including adversarial command, symlink, input-limit, process-group, output-cap,
and atomic-configuration cases. A dependency-free [demo workspace](examples/demo)
is included for live Quattro acceptance.

## What it does

- Shows `LW ready/total` in the bar; `!` marks projects needing attention.
- Adds and removes local repositories directly in the panel. No hand-edited
  configuration file is required after a standard install.
- Reads repository manifests passively. Nothing autostarts.
- **Start** first shows the exact command, resolved executable, real working
  directory, and local command origin. Only **Confirm & Start** authorizes that
  exact fingerprint once; any origin change requires a new review.
- Starts dependencies in order and supports workspace **Start all** / **Stop
  all** orchestration. Each command still receives its own review confirmation.
- Probes a numeric-loopback health URL every 500 ms for up to 30 seconds.
- Opens only validated numeric-loopback project URLs.
- Watches configuration and manifests for changes without touching running
  processes.
- Optionally sends status-only desktop notifications and opens a project when
  ready if both configuration and manifest opt in.
- Keeps a removed manifest entry visible until its live process group is
  stopped.

## Requirements

- Omarchy with the Quattro shell (plugin `schemaVersion` 1).
- Python 3 for the bundled bounded parser/process supervisor.
- `curl` for readiness probes and `stat` for manifest watching.
- `notify-send` only if notifications are enabled.
- The runtime used by each reviewed project command.

## Configure

Open LocalWrap from the Quattro bar, enter an existing local repository path,
and press **Add**. The helper resolves and stores the real path atomically.

Advanced users may manage `~/.config/localwrap/repositories.json` directly:

```json
{
  "repositories": ["/home/you/src/storefront"],
  "notifications": false,
  "openOnReady": false
}
```

Both optional flags default off. At most 16 repositories are accepted.

Each repository needs `.localwrap/workspace.json` or `localwrap.json`:

```json
{
  "localwrap": 1,
  "projects": [
    {
      "id": "web",
      "command": "pnpm run dev",
      "path": "apps/web",
      "port": 3000,
      "url": "http://127.0.0.1:3000",
      "healthCheck": { "path": "/health" }
    }
  ]
}
```

`localhost` is deliberately rejected. Use `127.0.0.1` or `[::1]` in project
and health-check URLs. If `url` is omitted it defaults to numeric IPv4 loopback.

## Execution review

A repository manifest may propose execution; it cannot authorize execution.
When Start is pressed, LocalWrap resolves and displays:

- the exact manifest command;
- the installed executable's canonical path;
- the real, repository-contained working directory;
- the manifest path; and
- either the exact local `package.json` script or the real interpreter script.

Confirm only if you trust that repository and exact command. The helper creates
a SHA-256 fingerprint over the complete launch plan and rebuilds it immediately
before execution. A changed manifest, package script, executable, path, or
symlink fails closed and requires review again.

## Security model

Omarchy plugins run unsandboxed in the shared shell, so LocalWrap treats every
repository and all live output as hostile input.

### Commands and origins

- `npx`, `npm exec`, `deno run`, eval flags, shell operators, quoting, and
  arbitrary interpreter paths are rejected.
- Package managers permit only `<npm|pnpm|yarn|bun> run <name>` plus
  `npm start`. The exact local package script is part of the review fingerprint.
- Node and Python require a real repository-contained script path.
- Support commands use fixed argument arrays. Manifest text is never passed to
  a shell by QML.

### Files and bounded parsing

- Repository roots, manifests, working directories, package files, and scripts
  are resolved on disk and must remain within the real repository root.
- Manifests and package files themselves may not be symlinks.
- Configuration is capped at 16 KiB and manifests at 64 KiB before decoding.
- JSON depth is capped at 12 before `json.loads`/`JSON.parse` materialization.
- A manifest permits at most 32 projects, 16 workspaces, 16 dependencies per
  project, and 32 members per workspace.
- IDs/names are capped at 128 characters, paths at 256, commands/URLs at 512,
  and command argument count/length at 32/256.
- Unknown schema fields are blockers.

### Network, processes, output, and rendering

- Project and probe URLs must be `http(s)` on numeric `127.0.0.1` or `[::1]`
  with an explicit port from 1000–65535. Hostnames, wildcard/LAN addresses,
  userinfo, and other schemes are rejected.
- Every server runs in an independent process group. Stop, plugin unload, or
  interruption sends TERM to the group, waits two seconds, then sends KILL.
- The helper drains child pipes in 4 KiB chunks, forwards at most 64 KiB total,
  and truncates each line at 2 KiB before QML receives it. The final bounded
  tail stays in memory and is never persisted.
- Every manifest-derived label, diagnostic, command, path, URL, notification,
  and process-output line uses explicit `Text.PlainText` rendering.

### Installation

The normal `omarchy plugin add` path is preferred. For a checkout, `install.sh`
provides the same payload safely:

```sh
./install.sh
# Existing owned installation only:
./install.sh --force
```

The installer rejects source/destination symlinks and ownership collisions,
stages the complete fixed payload beside the destination, verifies every
copied SHA-256, applies fixed modes, and atomically swaps it. An interrupted
replacement restores the previous complete directory.

## Development and verification

```sh
node --test tests/model.test.js
python3 -m unittest -v tests/test_helper.py
bash -n install.sh
git diff --check
```

On Omarchy:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/io.github.tcballard.localwrap
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/io.github.tcballard.localwrap/BarWidget.qml \
  ~/.config/omarchy/plugins/io.github.tcballard.localwrap/Panel.qml
```

## Remove

```sh
omarchy plugin remove io.github.tcballard.localwrap
```

Removal stops supervised process groups. Repositories, manifests, and
`~/.config/localwrap/repositories.json` are left untouched.

## License

Apache-2.0, same as LocalWrap. See [LICENSE](LICENSE).
