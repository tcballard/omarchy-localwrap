import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// LocalWrap cockpit panel.
//
// The bundled localwrap-helper is the trust boundary for bounded parsing,
// realpath containment, exact launch review, and process-group cleanup. QML
// consumes only its bounded normalized JSON and never executes manifest text.
//
// External commands used, all with fixed argument lists built in Model.js:
//   localwrap-helper  bounded config/manifest inspection and confirmed launch
//   curl         probe the loopback health-check URL (HEAD, 1 s budget)
//   stat         poll config/manifest mtimes so edits are picked up
//   notify-send  desktop notifications, only when enabled in configuration
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
  property bool configNotifications: false
  property bool configOpenOnReady: false
  property int loadGeneration: 0
  // orchestrations: repoRoot + "@" + workspaceID ->
  //   { repoRoot, workspaceId, name, plan, state, message } where state is
  //   "running", "halted", or "done".
  property var orchestrations: ({})
  // Last observed config/manifest mtimes; null until the first watch poll.
  property var watchTimes: null
  // One exact launch plan at a time. The user must inspect and confirm it;
  // the helper re-fingerprints every origin immediately before execution.
  property var pendingReview: null
  property string setupMessage: ""

  readonly property string homeDirectory: Quickshell.env("HOME") || ""
  readonly property string configPath:
    homeDirectory + "/.config/localwrap/repositories.json"
  readonly property string helperPath: localPath(Qt.resolvedUrl("localwrap-helper"))
  readonly property int maxTailLines: 20

  readonly property var summary: computeSummary(repositories, runtimes)
  readonly property string barText: Model.barLabel(summary)
  readonly property string barTooltip: Model.barTooltip(summary)
  readonly property bool anyStarting: computeAnyStarting(runtimes)
  readonly property var orphans: computeOrphans(repositories, runtimes)

  function localPath(url) {
    var value = String(url)
    return value.indexOf("file://") === 0 ? decodeURIComponent(value.slice(7)) : value
  }

  function parseHelperJSON(text) {
    // The helper already caps UTF-8 output at 128 KiB; enforce the same
    // character ceiling again before JSON.parse as defense in depth.
    if (typeof text !== "string" || text.length > 131072) return null
    try {
      var value = JSON.parse(text)
      return value !== null && typeof value === "object" ? value : null
    } catch (_error) {
      return null
    }
  }

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

  // Re-evaluate running workspace orchestrations whenever project state or
  // the repository listing changes. Qt.callLater collapses bursts.
  onRuntimesChanged: Qt.callLater(advanceOrchestrations)
  onRepositoriesChanged: Qt.callLater(advanceOrchestrations)

  // -------------------------------------------------------------------------
  // Configuration and manifest loading (read-only)
  // -------------------------------------------------------------------------

  function reload() {
    loadGeneration += 1
    var generation = loadGeneration
    repositories = []
    configError = ""
    configLoaded = false
    configNotifications = false
    configOpenOnReady = false
    if (homeDirectory === "") {
      configError = "Cannot resolve $HOME to locate the configuration."
      configLoaded = true
      return
    }
    runRead([helperPath, "config-get", configPath], function(exitCode, text) {
      if (generation !== root.loadGeneration) return
      root.configLoaded = true
      var parsed = parseHelperJSON(text)
      if (exitCode !== 0 || parsed === null || parsed.ok !== true) {
        root.configError = "Configuration could not be read safely."
        return
      }
      root.configNotifications = parsed.notifications === true
      root.configOpenOnReady = parsed.openOnReady === true
      if (parsed.repositories.length === 0) root.configError = "missing-config"
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
          workspaces: [],
          loading: true,
        })
      }
      root.repositories = placeholders
      for (var j = 0; j < parsed.repositories.length; j += 1)
        loadRepository(parsed.repositories[j], generation)
    })
  }

  function loadRepository(repositoryRoot, generation) {
    runRead([helperPath, "inspect", repositoryRoot], function(exitCode, text) {
      if (generation !== root.loadGeneration) return
      var result = parseHelperJSON(text)
      if (exitCode !== 0 || result === null) result = {
        ok: false, root: repositoryRoot, name: Model.basename(repositoryRoot),
        manifestPath: null, projects: [], workspaces: [], warnings: [],
        errors: [{ code: "helper-failed", scope: "manifest",
          message: "The bounded manifest inspector failed." }],
      }
      for (var i = 0; i < result.projects.length; i += 1) {
        var project = result.projects[i]
        project.repoRoot = result.root
        project.key = result.root + "#" + project.id
      }
      replaceRepository({
        root: result.root,
        name: result.name,
        manifestPath: result.manifestPath,
        ok: result.ok,
        errors: result.errors || [],
        warnings: result.warnings || [],
        projects: result.ok ? result.projects : [],
        workspaces: result.ok ? result.workspaces : [],
      })
    })
  }

  function addRepository(path) {
    setupMessage = "Checking repository…"
    runRead([helperPath, "config-add", configPath, path], function(exitCode, text) {
      var result = parseHelperJSON(text)
      if (exitCode !== 0 || result === null || result.ok !== true) {
        root.setupMessage = "Could not add that repository. Use an existing local directory."
        return
      }
      root.setupMessage = "Repository added."
      root.reload()
    })
  }

  function removeRepository(path) {
    runRead([helperPath, "config-remove", configPath, path], function(exitCode, text) {
      var result = parseHelperJSON(text)
      root.setupMessage = exitCode === 0 && result !== null && result.ok === true
        ? "Repository removed." : "Could not remove that repository."
      if (exitCode === 0) root.reload()
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
    if (!gate.ok || pendingReview !== null) return
    runRead([helperPath, "preflight", repository.root, project.id], function(exitCode, text) {
      if (root.pendingReview !== null) return
      var review = parseHelperJSON(text)
      if (exitCode !== 0 || review === null || review.ok !== true) {
        failStart(project, "Exact command/origin review failed. Check the manifest and local runtime.")
        return
      }
      review.project = project
      review.repository = repository
      root.pendingReview = review
    })
  }

  function confirmPendingReview() {
    if (pendingReview === null) return
    var review = pendingReview
    pendingReview = null
    var project = review.project
    setRuntime(project.key, {
      status: Model.STATUS.starting, name: project.name, url: project.url,
      message: "", tail: [], startedAt: Date.now(), probeInFlight: false,
    })
    runRead(Model.curlProbeArgv(project.healthCheckURL), function(_probeExit, body) {
      if (statusFor(project.key) !== Model.STATUS.starting) return
      if (Model.isReadyHttpCode(body)) {
        var conflictMessage = "Something is already responding at "
          + project.healthCheckURL + ". Not starting a second copy."
        setRuntime(project.key, {
          status: Model.STATUS.conflict,
          message: conflictMessage,
        })
        notifyTransition(project.name, Model.STATUS.conflict, conflictMessage)
        return
      }
      spawnRunner(project, review.fingerprint)
    })
  }

  function cancelPendingReview() {
    var cancelled = pendingReview
    pendingReview = null
    if (cancelled === null) return
    var keys = Object.keys(orchestrations)
    for (var i = 0; i < keys.length; i += 1) {
      var record = orchestrations[keys[i]]
      if (record.state === "running"
          && record.repoRoot === cancelled.repository.root
          && record.plan.indexOf(cancelled.project.id) !== -1) {
        setOrchestration(keys[i], orchestrationWith(record, "halted",
          "Halted: execution review was cancelled for " + cancelled.project.name + "."))
      }
    }
  }

  function failStart(project, message) {
    setRuntime(project.key, { status: Model.STATUS.failed, message: message })
    notifyTransition(project.name, Model.STATUS.failed, message)
  }

  function spawnRunner(project, fingerprint) {
    if (statusFor(project.key) !== Model.STATUS.starting) return
    var runner = runnerComponent.createObject(root, {
      projectKey: project.key,
      command: [helperPath, "run", project.repoRoot, project.id, fingerprint],
    })
    if (runner === null) {
      failStart(project, "Could not create the process object.")
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

  function stopAllProcesses() {
    var keys = Object.keys(activeProcesses)
    for (var i = 0; i < keys.length; i += 1) stopProject(keys[i])
  }

  Component.onDestruction: stopAllProcesses()

  function handleRunnerExit(key, exitCode, tail) {
    delete activeProcesses[key]
    if (runtimes[key] === undefined) return
    if (statusFor(key) === Model.STATUS.stopping) {
      setRuntime(key, { status: Model.STATUS.stopped, message: "", tail: [] })
      return
    }
    var exitMessage = "Exited unexpectedly (code " + exitCode + ")."
    setRuntime(key, {
      status: Model.STATUS.failed,
      message: exitMessage,
      tail: tail,
    })
    notifyTransition(runtimeFor(key).name, Model.STATUS.failed, exitMessage)
  }

  function pollStartingProjects() {
    var keys = Object.keys(runtimes)
    for (var i = 0; i < keys.length; i += 1) {
      var key = keys[i]
      var runtime = runtimes[key]
      if (runtime.status !== Model.STATUS.starting) continue
      if (Date.now() - runtime.startedAt > Model.READY_TIMEOUT_MS) {
        var stallMessage = "Process is running but " + runtime.url
          + " did not respond within "
          + Math.round(Model.READY_TIMEOUT_MS / 1000) + " s."
        setRuntime(key, { status: Model.STATUS.stalled, message: stallMessage })
        notifyTransition(runtime.name, Model.STATUS.stalled, stallMessage)
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
      if (Model.isReadyHttpCode(body)) {
        setRuntime(key, { status: Model.STATUS.ready, message: "" })
        var readyProject = projectForKey(key)
        var readyName = readyProject !== null ? readyProject.name : runtimeFor(key).name
        notifyTransition(readyName, Model.STATUS.ready,
          readyProject !== null ? readyProject.url : "")
        // Auto-open only when both the user's configuration and the
        // project's manifest opt in.
        if (root.configOpenOnReady && readyProject !== null && readyProject.openOnReady)
          openProject(readyProject)
      }
    })
  }

  function projectForKey(key) {
    for (var i = 0; i < repositories.length; i += 1) {
      for (var j = 0; j < repositories[i].projects.length; j += 1) {
        if (repositories[i].projects[j].key === key)
          return repositories[i].projects[j]
      }
    }
    return null
  }

  function probeURLFor(key) {
    var project = projectForKey(key)
    return project === null ? null : project.healthCheckURL
  }

  // Desktop notifications: opt-in via configuration, status transitions
  // only, never command output.
  function notifyTransition(name, status, detail) {
    if (!configNotifications) return
    var note = Model.notificationForTransition(name, status, detail)
    if (note === null) return
    runRead(Model.notifySendArgv(note.summary, note.body), function() {})
  }

  // -------------------------------------------------------------------------
  // Workspace orchestration
  // -------------------------------------------------------------------------

  function repoByRoot(repositoryRoot) {
    for (var i = 0; i < repositories.length; i += 1) {
      if (repositories[i].root === repositoryRoot) return repositories[i]
    }
    return null
  }

  function projectInRepo(repository, projectID) {
    for (var i = 0; i < repository.projects.length; i += 1) {
      if (repository.projects[i].id === projectID) return repository.projects[i]
    }
    return null
  }

  function orchestrationKey(repositoryRoot, workspaceID) {
    return repositoryRoot + "@" + workspaceID
  }

  function setOrchestration(key, record) {
    var next = {}
    var keys = Object.keys(orchestrations)
    for (var i = 0; i < keys.length; i += 1)
      next[keys[i]] = orchestrations[keys[i]]
    if (record === null) delete next[key]
    else next[key] = record
    orchestrations = next
  }

  function orchestrationWith(record, state, message) {
    return {
      repoRoot: record.repoRoot, workspaceId: record.workspaceId,
      name: record.name, plan: record.plan, state: state, message: message,
    }
  }

  function startWorkspace(repository, workspace) {
    var plan = Model.workspaceStartPlan(repository.projects, workspace)
    if (plan.length === 0) return
    setOrchestration(orchestrationKey(repository.root, workspace.id), {
      repoRoot: repository.root, workspaceId: workspace.id,
      name: workspace.name, plan: plan, state: "running", message: "",
    })
    Qt.callLater(advanceOrchestrations)
  }

  function stopWorkspace(repository, workspace) {
    var key = orchestrationKey(repository.root, workspace.id)
    var record = orchestrations[key]
    var plan = record !== undefined ? record.plan
      : Model.workspaceStartPlan(repository.projects, workspace)
    setOrchestration(key, null)
    var stops = Model.workspaceStopPlan(plan, repoStatusMap(repository, runtimes))
    for (var i = 0; i < stops.length; i += 1) {
      var project = projectInRepo(repository, stops[i])
      if (project !== null) stopProject(project.key)
    }
  }

  function advanceOrchestrations() {
    var keys = Object.keys(orchestrations)
    for (var i = 0; i < keys.length; i += 1) {
      var record = orchestrations[keys[i]]
      if (record.state !== "running") continue
      // A reload in flight briefly empties the repository list and leaves
      // loading placeholders; wait it out instead of halting spuriously.
      if (!configLoaded) continue
      var repository = repoByRoot(record.repoRoot)
      if (repository === null) {
        setOrchestration(keys[i], orchestrationWith(record, "halted",
          "Halted: the repository was removed from the configuration."))
        continue
      }
      if (repository.loading === true) continue
      if (repository.ok !== true) {
        setOrchestration(keys[i], orchestrationWith(record, "halted",
          "Halted: the repository manifest now has blockers."))
        continue
      }
      var projectsByID = {}
      for (var j = 0; j < repository.projects.length; j += 1)
        projectsByID[repository.projects[j].id] = repository.projects[j]
      var step = Model.orchestrationStep(
        record.plan, projectsByID, repoStatusMap(repository, runtimes))
      if (step.blocked !== null) {
        setOrchestration(keys[i], orchestrationWith(record, "halted",
          "Halted: " + step.blocked.id + " is "
          + Model.statusLabel(step.blocked.status).toLowerCase() + "."))
        continue
      }
      if (step.done) {
        setOrchestration(keys[i], orchestrationWith(record, "done",
          "All " + step.total + " projects ready."))
        if (configNotifications)
          runRead(Model.notifySendArgv(
            "Workspace " + record.name + " is ready",
            step.total + " projects ready"), function() {})
        continue
      }
      for (var s = 0; s < step.startNow.length; s += 1) {
        var project = projectsByID[step.startNow[s]]
        if (project === undefined) {
          setOrchestration(keys[i], orchestrationWith(record, "halted",
            "Halted: " + step.startNow[s] + " is no longer in the manifest."))
          break
        }
        startProject(repository, project)
      }
    }
  }

  function workspacePlanSummary(plan, repository, runtimeMap) {
    var ready = 0
    var running = 0
    for (var i = 0; i < plan.length; i += 1) {
      var project = projectInRepo(repository, plan[i])
      var status = Model.STATUS.stopped
      if (project !== null && runtimeMap[project.key] !== undefined)
        status = runtimeMap[project.key].status
      if (status === Model.STATUS.ready) ready += 1
      if (Model.isRunningStatus(status)) running += 1
    }
    return {
      ready: ready, running: running, total: plan.length,
      anyRunning: running > 0,
      allReady: plan.length > 0 && ready === plan.length,
    }
  }

  function workspaceStatusColor(record, planSummary) {
    if (record !== undefined && record !== null && record.state === "halted")
      return Model.statusColor(Model.STATUS.failed)
    if (planSummary.allReady) return Model.statusColor(Model.STATUS.ready)
    if (planSummary.anyRunning) return Model.statusColor(Model.STATUS.starting)
    return Model.statusColor(Model.STATUS.stopped)
  }

  // -------------------------------------------------------------------------
  // Manifest change watching
  // -------------------------------------------------------------------------

  function pollWatchedFiles() {
    if (homeDirectory === "") return
    // While a reload is in flight the repository list is momentarily empty;
    // polling then would diff against a shrunken path set and re-trigger.
    if (!configLoaded) return
    var roots = []
    for (var i = 0; i < repositories.length; i += 1)
      roots.push(repositories[i].root)
    runRead(Model.statWatchArgv(Model.watchPathsFor(configPath, roots)),
      function(_exitCode, text) {
        var times = Model.parseStatTimes(text)
        var changed = root.watchTimes !== null
          && !Model.sameStatTimes(root.watchTimes, times)
        root.watchTimes = times
        // Reload preserves runtimes; running processes are never touched.
        if (changed) root.reload()
      })
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

  Timer {
    interval: Model.WATCH_POLL_INTERVAL_MS
    repeat: true
    running: true
    onTriggered: root.pollWatchedFiles()
  }

  // -------------------------------------------------------------------------
  // Bounded one-shot helper/probe readers and supervised project runners
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

  // Repository manifests and process output are hostile display input. Every
  // text surface uses this component so QML never interprets rich-text tags.
  component SafeText: Text {
    textFormat: Text.PlainText
  }

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
    SafeText {
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
            SafeText {
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

          // Standard-install onboarding: repository configuration is managed
          // atomically by the helper, so no hand-edited JSON is required.
          Column {
            width: parent.width
            spacing: Style.space(4)
            SafeText {
              width: parent.width
              text: "Add a local repository"
              color: root.mutedForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.smallFontSize
            }
            Row {
              width: parent.width
              spacing: Style.space(6)
              Rectangle {
                width: parent.width - addRepositoryButton.width - Style.space(6)
                height: addRepositoryButton.height
                radius: Style.space(4)
                color: Qt.alpha(root.barForeground, 0.06)
                border.width: 1
                border.color: Qt.alpha(root.barForeground, 0.2)
                TextInput {
                  id: repositoryPathInput
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.smallFontSize
                  clip: true
                  selectByMouse: true
                }
                SafeText {
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  visible: repositoryPathInput.text === ""
                  text: "/home/you/src/project"
                  color: root.faintForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.smallFontSize
                }
              }
              ActionButton {
                id: addRepositoryButton
                label: "Add"
                actionEnabled: repositoryPathInput.text.trim() !== ""
                onActivated: {
                  root.addRepository(repositoryPathInput.text)
                  repositoryPathInput.text = ""
                }
              }
            }
            SafeText {
              width: parent.width
              visible: root.setupMessage !== ""
              text: root.setupMessage
              color: root.faintForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.smallFontSize
              wrapMode: Text.WordWrap
            }
          }

          // A manifest can propose execution, but cannot authorize it. This
          // card exposes the exact argv, resolved executable, working directory,
          // and command origin before a one-time fingerprint confirmation.
          Rectangle {
            width: parent.width
            visible: root.pendingReview !== null
            implicitHeight: reviewColumn.implicitHeight + Style.space(16)
            radius: Style.space(6)
            color: Qt.alpha(Model.statusColor(Model.STATUS.stalled), 0.08)
            border.width: 1
            border.color: Qt.alpha(Model.statusColor(Model.STATUS.stalled), 0.5)
            Column {
              id: reviewColumn
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)
              SafeText {
                width: parent.width
                text: root.pendingReview !== null
                  ? "Review execution — " + root.pendingReview.projectName : ""
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                font.bold: true
                wrapMode: Text.WordWrap
              }
              SafeText {
                width: parent.width
                text: root.pendingReview !== null
                  ? "Command: " + root.pendingReview.displayCommand
                    + "\nResolved executable: " + root.pendingReview.executable
                    + "\nWorking directory: " + root.pendingReview.cwd
                    + "\nOrigin: " + root.pendingReview.reviewDetail : ""
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                wrapMode: Text.WrapAnywhere
              }
              SafeText {
                width: parent.width
                text: "Confirm only if you trust this repository and exact command. Any origin change invalidates this review."
                color: Model.statusColor(Model.STATUS.stalled)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                wrapMode: Text.WordWrap
              }
              Row {
                spacing: Style.space(6)
                ActionButton {
                  label: "Cancel"
                  onActivated: root.cancelPendingReview()
                }
                ActionButton {
                  label: "Confirm & Start"
                  accent: Model.statusColor(Model.STATUS.ready)
                  onActivated: root.confirmPendingReview()
                }
              }
            }
          }

          // Configuration guidance and errors
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.configLoaded && root.configError !== ""
            SafeText {
              width: parent.width
              text: root.configError === "missing-config"
                ? "No repositories configured yet."
                : "Configuration problem:\n" + root.configError
              color: root.mutedForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.smallFontSize
              wrapMode: Text.WordWrap
            }
            SafeText {
              width: parent.width
              visible: root.configError === "missing-config"
              text: "Enter an existing repository path above and press Add."
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
                SafeText {
                  width: parent.width
                  text: repositoryDelegate.repository.name
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.subtitle
                  elide: Text.ElideRight
                }
                SafeText {
                  width: parent.width
                  text: repositoryDelegate.repository.root
                  color: root.faintForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.smallFontSize
                  elide: Text.ElideMiddle
                }
              }

              SafeText {
                width: parent.width
                visible: repositoryDelegate.repository.loading === true
                text: "Reading manifest…"
                color: root.faintForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
              }

              // Manifest blockers keep the repository visible but inert,
              // mirroring the app's review: blockers disable import.
              SafeText {
                width: parent.width
                visible: !repositoryDelegate.repository.ok
                text: root.diagnosticsText(repositoryDelegate.repository.errors)
                color: Model.statusColor(Model.STATUS.failed)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                wrapMode: Text.WordWrap
              }
              SafeText {
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
                      SafeText {
                        width: parent.width
                        text: projectDelegate.project.name + "  ·  "
                          + Model.statusLabel(projectDelegate.projectStatus)
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: root.smallFontSize
                        elide: Text.ElideRight
                      }
                      SafeText {
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

                  SafeText {
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
                    SafeText {
                      width: parent.width
                      text: projectDelegate.runtime.message
                      color: Model.statusColor(projectDelegate.projectStatus)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: root.smallFontSize
                      wrapMode: Text.WordWrap
                    }
                    Repeater {
                      model: projectDelegate.runtime.tail.slice(-6)
                      delegate: SafeText {
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

              SafeText {
                width: parent.width
                visible: (repositoryDelegate.repository.workspaces || []).length > 0
                text: "Workspaces"
                color: root.mutedForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.smallFontSize
                font.bold: true
              }

              Repeater {
                model: repositoryDelegate.repository.workspaces || []
                delegate: Column {
                  id: workspaceDelegate
                  required property var modelData
                  readonly property var workspace: modelData
                  readonly property var record: root.orchestrations[
                    root.orchestrationKey(repositoryDelegate.repository.root, workspace.id)]
                  readonly property var plan: Model.workspaceStartPlan(
                    repositoryDelegate.repository.projects, workspace)
                  readonly property var planSummary: root.workspacePlanSummary(
                    plan, repositoryDelegate.repository, root.runtimes)
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
                      color: root.workspaceStatusColor(
                        workspaceDelegate.record, workspaceDelegate.planSummary)
                    }

                    Column {
                      width: parent.width - Style.space(8) - workspaceActions.width - Style.space(12)
                      anchors.verticalCenter: parent.verticalCenter
                      SafeText {
                        width: parent.width
                        text: workspaceDelegate.workspace.name + "  ·  "
                          + workspaceDelegate.planSummary.ready + "/"
                          + workspaceDelegate.planSummary.total + " ready"
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: root.smallFontSize
                        elide: Text.ElideRight
                      }
                      SafeText {
                        width: parent.width
                        text: workspaceDelegate.plan.join(" → ")
                        color: root.faintForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: root.smallFontSize
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: workspaceActions
                      spacing: Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      ActionButton {
                        visible: !(workspaceDelegate.record !== undefined
                          && workspaceDelegate.record.state === "running")
                        label: "Start all"
                        accent: Model.statusColor(Model.STATUS.ready)
                        onActivated: root.startWorkspace(
                          repositoryDelegate.repository, workspaceDelegate.workspace)
                      }
                      ActionButton {
                        visible: workspaceDelegate.planSummary.anyRunning
                          || (workspaceDelegate.record !== undefined
                            && workspaceDelegate.record.state === "running")
                        label: "Stop all"
                        accent: Model.statusColor(Model.STATUS.failed)
                        onActivated: root.stopWorkspace(
                          repositoryDelegate.repository, workspaceDelegate.workspace)
                      }
                    }
                  }

                  SafeText {
                    width: parent.width
                    visible: workspaceDelegate.record !== undefined
                      && workspaceDelegate.record.message !== ""
                    text: workspaceDelegate.record !== undefined
                      ? workspaceDelegate.record.message : ""
                    color: workspaceDelegate.record !== undefined
                      && workspaceDelegate.record.state === "halted"
                      ? Model.statusColor(Model.STATUS.failed)
                      : root.mutedForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.smallFontSize
                    wrapMode: Text.WordWrap
                  }
                }
              }

              ActionButton {
                visible: repositoryDelegate.repository.loading !== true
                label: "Remove repository"
                accent: root.mutedForeground
                onActivated: root.removeRepository(repositoryDelegate.repository.root)
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
                SafeText {
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

          SafeText {
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
