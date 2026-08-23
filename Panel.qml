import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// LocalWrap cockpit panel.
//
// Reads the repository list from ~/.config/localwrap/repositories.json, then
// each repository's LocalWrap workspace manifest (.localwrap/workspace.json,
// falling back to localwrap.json). Reading is always passive: nothing starts
// until the user presses Start on a reviewed row.
//
// External commands used, all with fixed argument lists built in Model.js:
//   cat    read the configuration and manifest files
//   which  confirm a manifest executable exists before launching it
//   curl   probe the loopback health-check URL (HEAD, 1 s budget)
// Project commands themselves are restricted to the LocalWrap executable
// allowlist and are launched directly — never through a shell.
Panel {
  id: root
  moduleName: "io.github.tcballard.localwrap"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // repositories: [{ root, name, manifestPath, ok, errors, warnings,
  //                  projects: [project + key/cwd/repoRoot] }]
  property var repositories: []
  // runtimes: key -> { status, name, url, message, tail, startedAt,
  //                    probeInFlight } — in-memory only, never persisted.
  property var runtimes: ({})
  property var activeProcesses: ({})
  property string configError: ""
  property bool configLoaded: false
  property int loadGeneration: 0

  readonly property string homeDirectory: Quickshell.env("HOME") || ""
  readonly property string configPath:
    homeDirectory + "/.config/localwrap/repositories.json"
  readonly property int maxTailLines: 20

  readonly property var summary: computeSummary(repositories, runtimes)
  readonly property string barText: Model.barLabel(summary)
  readonly property string barTooltip: Model.barTooltip(summary)
  readonly property bool anyStarting: computeAnyStarting(runtimes)
  readonly property var orphans: computeOrphans(repositories, runtimes)

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  Component.onCompleted: reload()

  // -------------------------------------------------------------------------
  // Configuration and manifest loading (read-only)
  // -------------------------------------------------------------------------

  function reload() {
    loadGeneration += 1
    var generation = loadGeneration
    repositories = []
    configError = ""
    configLoaded = false
    if (homeDirectory === "") {
      configError = "Cannot resolve $HOME to locate the configuration."
      configLoaded = true
      return
    }
    runRead(["cat", configPath], function(exitCode, text) {
      if (generation !== root.loadGeneration) return
      root.configLoaded = true
      if (exitCode !== 0) {
        root.configError = "missing-config"
        return
      }
      var parsed = Model.parseRepositoriesConfig(text, root.homeDirectory)
      if (!parsed.ok) {
        root.configError = diagnosticsText(parsed.errors)
        return
      }
      if (parsed.repositories.length === 0) {
        root.configError = "missing-config"
        return
      }
      // Placeholders keep the listing in configuration order even though
      // manifest reads complete asynchronously.
      var placeholders = []
      for (var i = 0; i < parsed.repositories.length; i += 1) {
        placeholders.push({
          root: parsed.repositories[i],
          name: Model.basename(parsed.repositories[i]),
          manifestPath: null,
          ok: true,
          errors: [],
          warnings: [],
          projects: [],
          loading: true,
        })
      }
      root.repositories = placeholders
      for (var j = 0; j < parsed.repositories.length; j += 1)
        loadRepository(parsed.repositories[j], generation)
    })
  }

  function loadRepository(repositoryRoot, generation) {
    tryManifest(repositoryRoot, Model.manifestCandidatePaths(repositoryRoot), 0, generation)
  }

  function tryManifest(repositoryRoot, candidates, index, generation) {
    if (index >= candidates.length) {
      replaceRepository({
        root: repositoryRoot,
        name: Model.basename(repositoryRoot),
        manifestPath: null,
        ok: false,
        errors: [{
          code: "manifest-missing", scope: "repository",
          message: "No " + Model.MANIFEST_RELATIVE_PATHS.join(" or ") + " found.",
        }],
        warnings: [],
        projects: [],
      })
      return
    }
    runRead(["cat", candidates[index]], function(exitCode, text) {
      if (generation !== root.loadGeneration) return
      if (exitCode !== 0) {
        tryManifest(repositoryRoot, candidates, index + 1, generation)
        return
      }
      var result = Model.parseWorkspaceManifest(text, Model.basename(repositoryRoot))
      for (var i = 0; i < result.projects.length; i += 1) {
        var project = result.projects[i]
        project.repoRoot = repositoryRoot
        project.key = repositoryRoot + "#" + project.id
        project.cwd = Model.joinPath(repositoryRoot, project.path)
      }
      replaceRepository({
        root: repositoryRoot,
        name: result.name,
        manifestPath: candidates[index],
        ok: result.ok,
        errors: result.errors,
        warnings: result.warnings,
        projects: result.ok ? result.projects : [],
      })
    })
  }

  function replaceRepository(repository) {
    var next = []
    for (var i = 0; i < repositories.length; i += 1)
      next.push(repositories[i].root === repository.root ? repository : repositories[i])
    repositories = next
  }

  function diagnosticsText(diagnostics) {
    var lines = []
    for (var i = 0; i < diagnostics.length; i += 1)
      lines.push(diagnostics[i].scope + ": " + diagnostics[i].message)
    return lines.join("\n")
  }

  // -------------------------------------------------------------------------
  // Runtime state
  // -------------------------------------------------------------------------

  function runtimeFor(key) {
    var runtime = runtimes[key]
    if (runtime === undefined) {
      return {
        status: Model.STATUS.stopped, name: "", url: "",
        message: "", tail: [], startedAt: 0, probeInFlight: false,
      }
    }
    return runtime
  }

  function statusFor(key) {
    return runtimeFor(key).status
  }

  function setRuntime(key, patch) {
    var next = {}
    var existingKeys = Object.keys(runtimes)
    for (var i = 0; i < existingKeys.length; i += 1)
      next[existingKeys[i]] = runtimes[existingKeys[i]]
    var base = runtimeFor(key)
    var merged = {
      status: base.status, name: base.name, url: base.url,
      message: base.message, tail: base.tail,
      startedAt: base.startedAt, probeInFlight: base.probeInFlight,
    }
    var patchKeys = Object.keys(patch)
    for (var j = 0; j < patchKeys.length; j += 1)
      merged[patchKeys[j]] = patch[patchKeys[j]]
    next[key] = merged
    runtimes = next
  }

  function computeSummary(repos, runtimeMap) {
    var statuses = []
    for (var i = 0; i < repos.length; i += 1) {
      for (var j = 0; j < repos[i].projects.length; j += 1) {
        var runtime = runtimeMap[repos[i].projects[j].key]
        statuses.push(runtime === undefined ? Model.STATUS.stopped : runtime.status)
      }
    }
    return Model.summarizeStatuses(statuses)
  }

  function computeAnyStarting(runtimeMap) {
    var keys = Object.keys(runtimeMap)
    for (var i = 0; i < keys.length; i += 1) {
      if (runtimeMap[keys[i]].status === Model.STATUS.starting) return true
    }
    return false
  }

  // Running processes whose project vanished from the manifest after a
  // rescan stay visible so they can still be stopped — never lose track of
  // a process the user started.
  function computeOrphans(repos, runtimeMap) {
    var known = {}
    for (var i = 0; i < repos.length; i += 1) {
      for (var j = 0; j < repos[i].projects.length; j += 1)
        known[repos[i].projects[j].key] = true
    }
    var result = []
    var keys = Object.keys(runtimeMap)
    for (var k = 0; k < keys.length; k += 1) {
      if (known[keys[k]] !== true && Model.isRunningStatus(runtimeMap[keys[k]].status))
        result.push({ key: keys[k], name: runtimeMap[keys[k]].name })
    }
    return result
  }

  function repoStatusMap(repository, runtimeMap) {
    var map = {}
    for (var i = 0; i < repository.projects.length; i += 1) {
      var project = repository.projects[i]
      var runtime = runtimeMap[project.key]
      map[project.id] = runtime === undefined ? Model.STATUS.stopped : runtime.status
    }
    return map
  }

  // -------------------------------------------------------------------------
  // Start / stop / readiness
  // -------------------------------------------------------------------------

  function startProject(repository, project) {
    var gate = Model.canStart(project, repoStatusMap(repository, runtimes))
    if (!gate.ok) return
    setRuntime(project.key, {
      status: Model.STATUS.starting, name: project.name, url: project.url,
      message: "", tail: [], startedAt: Date.now(), probeInFlight: false,
    })
    runRead(["which", project.command.executable], function(whichExit) {
      if (statusFor(project.key) !== Model.STATUS.starting) return
      if (whichExit !== 0) {
        setRuntime(project.key, {
          status: Model.STATUS.failed,
          message: "Executable \"" + project.command.executable
            + "\" was not found on PATH.",
        })
        return
      }
      runRead(Model.curlProbeArgv(project.healthCheckURL), function(_probeExit, body) {
        if (statusFor(project.key) !== Model.STATUS.starting) return
        if (Model.isReadyHttpCode(body)) {
          setRuntime(project.key, {
            status: Model.STATUS.conflict,
            message: "Something is already responding at " + project.healthCheckURL
              + ". Not starting a second copy.",
          })
          return
        }
        spawnRunner(project)
      })
    })
  }

  function spawnRunner(project) {
    if (statusFor(project.key) !== Model.STATUS.starting) return
    var runner = runnerComponent.createObject(root, {
      projectKey: project.key,
      command: project.command.argv,
      workingDirectory: project.cwd,
      environment: { PORT: String(project.port) },
    })
    if (runner === null) {
      setRuntime(project.key, {
        status: Model.STATUS.failed,
        message: "Could not create the process object.",
      })
      return
    }
    activeProcesses[project.key] = runner
    runner.running = true
  }

  function stopProject(key) {
    var runner = activeProcesses[key]
    if (runner === undefined || runner === null || !runner.running) {
      delete activeProcesses[key]
      setRuntime(key, { status: Model.STATUS.stopped, message: "" })
      return
    }
    setRuntime(key, { status: Model.STATUS.stopping, message: "" })
    runner.running = false
  }

  function handleRunnerExit(key, exitCode, tail) {
    delete activeProcesses[key]
    if (runtimes[key] === undefined) return
    if (statusFor(key) === Model.STATUS.stopping) {
      setRuntime(key, { status: Model.STATUS.stopped, message: "", tail: [] })
      return
    }
    setRuntime(key, {
      status: Model.STATUS.failed,
      message: "Exited unexpectedly (code " + exitCode + ").",
      tail: tail,
    })
  }

  function pollStartingProjects() {
    var keys = Object.keys(runtimes)
    for (var i = 0; i < keys.length; i += 1) {
      var key = keys[i]
      var runtime = runtimes[key]
      if (runtime.status !== Model.STATUS.starting) continue
      if (Date.now() - runtime.startedAt > Model.READY_TIMEOUT_MS) {
        setRuntime(key, {
          status: Model.STATUS.stalled,
          message: "Process is running but " + runtime.url + " did not respond within "
            + Math.round(Model.READY_TIMEOUT_MS / 1000) + " s.",
        })
        continue
      }
      if (runtime.probeInFlight) continue
      probeProject(key)
    }
  }

  function probeProject(key) {
    var probeURL = probeURLFor(key)
    if (probeURL === null) return
    setRuntime(key, { probeInFlight: true })
    runRead(Model.curlProbeArgv(probeURL), function(_exitCode, body) {
      if (root.runtimes[key] === undefined) return
      setRuntime(key, { probeInFlight: false })
      if (statusFor(key) !== Model.STATUS.starting) return
      if (Model.isReadyHttpCode(body))
        setRuntime(key, { status: Model.STATUS.ready, message: "" })
    })
  }

  function probeURLFor(key) {
    for (var i = 0; i < repositories.length; i += 1) {
      for (var j = 0; j < repositories[i].projects.length; j += 1) {
        if (repositories[i].projects[j].key === key)
          return repositories[i].projects[j].healthCheckURL
      }
    }
    return null
  }

  function openProject(project) {
    // Revalidated at click time: only validated loopback URLs ever open.
    var validated = Model.validateLoopbackURL(project.url)
    if (validated.ok) Qt.openUrlExternally(validated.href)
  }

  Timer {
    interval: Model.READY_POLL_INTERVAL_MS
    repeat: true
    running: root.anyStarting
    onTriggered: root.pollStartingProjects()
  }

  // -------------------------------------------------------------------------
  // One-shot readers (cat / which / curl) and project runners
  // -------------------------------------------------------------------------

  Component {
    id: readerComponent
    Process {
      id: readerProcess
      property var callback: null
      property int collectedExitCode: -1
      property bool exitSeen: false
      property bool streamSeen: false
      property string collected: ""
      stdout: StdioCollector {
        id: readerCollector
        onStreamFinished: {
          readerProcess.collected = readerCollector.text
          readerProcess.streamSeen = true
          readerProcess.maybeFinish()
        }
      }
      onExited: function(exitCode, _exitStatus) {
        readerProcess.collectedExitCode = exitCode
        readerProcess.exitSeen = true
        readerProcess.maybeFinish()
      }
      function maybeFinish() {
        if (!exitSeen || !streamSeen) return
        var finish = callback
        callback = null
        if (finish) finish(collectedExitCode, collected)
        readerProcess.destroy()
      }
    }
  }

  function runRead(argv, callback) {
    var reader = readerComponent.createObject(root, { command: argv, callback: callback })
    if (reader === null) {
      callback(127, "")
      return
    }
    reader.running = true
  }

  Component {
    id: runnerComponent
    Process {
      id: runnerProcess
      property string projectKey: ""
      property var tail: []
      stdout: SplitParser {
        onRead: function(data) {
          runnerProcess.tail = Model.appendOutputTail(runnerProcess.tail, data, root.maxTailLines)
        }
      }
      stderr: SplitParser {
        onRead: function(data) {
          runnerProcess.tail = Model.appendOutputTail(runnerProcess.tail, data, root.maxTailLines)
        }
      }
      onExited: function(exitCode, _exitStatus) {
        root.handleRunnerExit(runnerProcess.projectKey, exitCode, runnerProcess.tail)
        runnerProcess.destroy()
      }
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  readonly property color mutedForeground: Qt.alpha(root.barForeground, 0.65)
  readonly property color faintForeground: Qt.alpha(root.barForeground, 0.4)
  readonly property int smallFontSize: Math.max(9, Math.round(Style.font.subtitle * 0.8))

  component ActionButton: Rectangle {
    id: actionButton
    property string label: ""
    property bool actionEnabled: true
    property color accent: root.barForeground
    signal activated()
    implicitWidth: actionLabel.implicitWidth + Style.space(16)
    implicitHeight: actionLabel.implicitHeight + Style.space(8)
    radius: Style.space(4)
    color: actionArea.containsMouse && actionButton.actionEnabled
      ? Qt.alpha(actionButton.accent, 0.18)
      : "transparent"
    border.width: 1
    border.color: Qt.alpha(actionButton.accent, actionButton.actionEnabled ? 0.5 : 0.2)
    opacity: actionButton.actionEnabled ? 1.0 : 0.45
    Text {
      id: actionLabel
      anchors.centerIn: parent
      text: actionButton.label
      color: actionButton.accent
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: root.smallFontSize
    }
    MouseArea {
      id: actionArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: actionButton.actionEnabled
      onClicked: actionButton.activated()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(
      Math.min(contentColumn.implicitHeight, Style.space(440)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width - rescanButton.width - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "LocalWrap"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }
            ActionButton {
              id: rescanButton
              anchors.verticalCenter: parent.verticalCenter
              label: "Rescan"
              onActivated: root.reload()
            }
          }

          // Configuration guidance and errors
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.configLoaded && root.configError !== ""
            Text {
              width: parent.width
              text: root.configError === "missing-config"
                ? "No repositories configured yet."
                : "Configuration problem:\n" + root.configError
              color: root.mutedForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.smallFontSize
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              visible: root.configError === "missing-config"
              text: "List the repositories that contain a LocalWrap manifest in\n"
                + root.configPath + "\n\n"
                + "{ \"repositories\": [\"~/src/my-app\"] }"
              color: root.faintForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.smallFontSize
              wrapMode: Text.WrapAnywhere
            }
          }

          // Repositories
          Repeater {
            model: root.repositories
            delegate: Column {
              id: repositoryDelegate
              required property var modelData
              readonly property var repository: modelData
              width: parent.width
              spacing: Style.space(6)

              Column {
                width: parent.width
                spacing: 0
                Text {
                  width: parent.width
                  text: repositoryDelegate.repository.name
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: repositoryDelegate.repository.root
                  color: root.faintForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.smallFontSize
                  elide: Text.ElideMiddle
                }
              }

              Text {
                width: parent.width
                visible: repositoryDelegate.repository.loading === true
                text: "Reading manifest…"
                color: root.faintForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
              }

              // Manifest blockers keep the repository visible but inert,
              // mirroring the app's review: blockers disable import.
              Text {
                width: parent.width
                visible: !repositoryDelegate.repository.ok
                text: root.diagnosticsText(repositoryDelegate.repository.errors)
                color: Model.statusColor(Model.STATUS.failed)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: repositoryDelegate.repository.warnings.length > 0
                text: root.diagnosticsText(repositoryDelegate.repository.warnings)
                color: Model.statusColor(Model.STATUS.stalled)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                wrapMode: Text.WordWrap
              }

              Repeater {
                model: repositoryDelegate.repository.projects
                delegate: Column {
                  id: projectDelegate
                  required property var modelData
                  readonly property var project: modelData
                  readonly property var runtime: root.runtimeFor(project.key)
                  readonly property string projectStatus: runtime.status
                  readonly property var gate: Model.canStart(
                    project, root.repoStatusMap(repositoryDelegate.repository, root.runtimes))
                  width: parent.width
                  spacing: Style.space(2)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)

                    Rectangle {
                      width: Style.space(8)
                      height: Style.space(8)
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: Model.statusColor(projectDelegate.projectStatus)
                    }

                    Column {
                      width: parent.width - Style.space(8) - actionRow.width - Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        width: parent.width
                        text: projectDelegate.project.name + "  ·  "
                          + Model.statusLabel(projectDelegate.projectStatus)
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: root.smallFontSize
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        text: projectDelegate.project.commandLine + "  →  "
                          + projectDelegate.project.url
                        color: root.faintForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: root.smallFontSize
                        elide: Text.ElideMiddle
                      }
                    }

                    Row {
                      id: actionRow
                      spacing: Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      ActionButton {
                        visible: !Model.isRunningStatus(projectDelegate.projectStatus)
                        label: "Start"
                        actionEnabled: projectDelegate.gate.ok
                        accent: Model.statusColor(Model.STATUS.ready)
                        onActivated: root.startProject(
                          repositoryDelegate.repository, projectDelegate.project)
                      }
                      ActionButton {
                        visible: Model.isRunningStatus(projectDelegate.projectStatus)
                          && projectDelegate.projectStatus !== Model.STATUS.stopping
                        label: "Stop"
                        accent: Model.statusColor(Model.STATUS.failed)
                        onActivated: root.stopProject(projectDelegate.project.key)
                      }
                      ActionButton {
                        visible: projectDelegate.projectStatus === Model.STATUS.ready
                          || projectDelegate.projectStatus === Model.STATUS.conflict
                        label: "Open"
                        onActivated: root.openProject(projectDelegate.project)
                      }
                    }
                  }

                  Text {
                    width: parent.width
                    visible: !projectDelegate.gate.ok
                      && !Model.isRunningStatus(projectDelegate.projectStatus)
                      && projectDelegate.gate.reason.indexOf("Waiting on") === 0
                    text: projectDelegate.gate.reason
                    color: Model.statusColor(Model.STATUS.stalled)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.smallFontSize
                    wrapMode: Text.WordWrap
                  }

                  Column {
                    width: parent.width
                    visible: projectDelegate.runtime.message !== ""
                    Text {
                      width: parent.width
                      text: projectDelegate.runtime.message
                      color: Model.statusColor(projectDelegate.projectStatus)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: root.smallFontSize
                      wrapMode: Text.WordWrap
                    }
                    Repeater {
                      model: projectDelegate.runtime.tail.slice(-6)
                      delegate: Text {
                        required property string modelData
                        width: contentColumn.width
                        text: modelData
                        color: root.faintForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: root.smallFontSize
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }
            }
          }

          // Running processes whose manifest entry disappeared after a rescan
          Column {
            width: parent.width
            visible: root.orphans.length > 0
            spacing: Style.space(4)
            Repeater {
              model: root.orphans
              delegate: Row {
                id: orphanDelegate
                required property var modelData
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: parent.width - orphanStop.width - Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  text: orphanDelegate.modelData.name + " — no longer in a manifest"
                  color: root.mutedForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.smallFontSize
                  elide: Text.ElideRight
                }
                ActionButton {
                  id: orphanStop
                  label: "Stop"
                  accent: Model.statusColor(Model.STATUS.failed)
                  onActivated: root.stopProject(orphanDelegate.modelData.key)
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.configError === ""
            text: root.configPath
            color: root.faintForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.smallFontSize
            elide: Text.ElideMiddle
          }
        }
      }
    }
  }
}
