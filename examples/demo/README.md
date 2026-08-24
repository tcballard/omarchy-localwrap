# LocalWrap Demo Workspace

A dependency-free two-project fixture for exercising every plugin feature,
including workspace orchestration. The manifest lives at the canonical
`.localwrap/workspace.json` location and declares:

- **api** (`node server.js`, port 4301) — waits ~2.5 s before listening, so
  the yellow Starting state is visible.
- **web** (`node server.js`, port 4302) — `dependsOn: ["api"]`, so it stays
  gated until the API is Ready.
- **Full stack** workspace — `api → web` start order.

## Use it

Point the plugin at this folder (installed via `omarchy plugin add`, it sits
inside the plugin directory):

```json
{
  "repositories": [
    "~/.config/omarchy/plugins/io.github.tcballard.localwrap/examples/demo"
  ],
  "notifications": true
}
```

in `~/.config/localwrap/repositories.json`, then open the `LW` widget.

Suggested walk-through: press **Start all** on *Full stack* and watch api go
yellow → green before web starts; **Open** web when ready; occupy a port
first (`python3 -m http.server 4301`) and press Start on api to see the
conflict refusal; `kill` the api process externally to see Failed plus its
output tail; edit the manifest while web runs to see the automatic reload
and, if you remove the project, its orphaned still-running row.
