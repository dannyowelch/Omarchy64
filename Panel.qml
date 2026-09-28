import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.dannyowelch.omarchy64"
  ipcTarget: "io.github.dannyowelch.omarchy64"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property var status: Model.emptyStatus()
  property bool busy: false
  property bool pendingLaunch: false
  property bool pendingReopen: false
  property string lastError: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property string browseThen: "launch"
  property bool tapePlayDown: false
  property bool tapeRecordArmed: false
  property double tapeCycles: 0
  property string tapeMotion: "stop"
  property double tapeAnchorMs: 0
  property int tapeTick: 0
  property bool tapeWherePending: false

  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return decodeURIComponent(s.replace(/\/$/, ""))
  }
  readonly property string ctl: pluginDir + "/omarchy64-ctl"
  readonly property string runner: pluginDir + "/omarchy64-run.py"
  readonly property var items: Model.cursorItems(status)
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.4)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool emulatorFound: status.emulator && status.emulator.found
  readonly property bool isPlaying: status.running && status.running.active
  readonly property bool isPaused: root.isPlaying && status.running.paused === true
  readonly property bool tapeDeckReady: !busy && isPlaying && status.tape !== "" && !browseProc.running
  readonly property bool dropdownOpen: joystickBox.popupOpen === true
  readonly property int ctlOutputCap: 65536
  readonly property int ctlErrorCap: 4096
  readonly property int browseOutputCap: 8192
  readonly property int statusDeadlineMs: 8000
  readonly property int ensureDeadlineMs: 8000
  readonly property int actionDeadlineMs: 30000
  readonly property int browseDeadlineMs: 300000
  readonly property int killGraceMs: 1000
  function buildCtlEnv() {
    var env = { PATH: "/usr/bin:/bin", LC_ALL: "C" }
    var keys = ["HOME", "USER", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR",
                "HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY",
                "DBUS_SESSION_BUS_ADDRESS", "LANG"]
    for (var i = 0; i < keys.length; i++) {
      var value = Quickshell.env(keys[i])
      if (value) env[keys[i]] = value
    }
    return env
  }

  readonly property var ctlEnv: buildCtlEnv()

  function open() {
    refresh()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  function ingest(raw) {
    var text = String(raw || "")
    if (text.length > root.ctlOutputCap) return
    var next = Model.parseStatus(text)
    var playing = next.running && next.running.active
    var nextPid = next.running ? (next.running.pid || 0) : 0
    var oldPid = root.status.running ? (root.status.running.pid || 0) : 0
    if (!playing || next.tape !== root.status.tape || nextPid !== oldPid) {
      root.tapePlayDown = false
      root.tapeRecordArmed = false
      root.tapeMotion = "stop"
      root.tapeCycles = 0
      root.tapeAnchorMs = Date.now()
    }
    if (typeof next.tapeCycles === "number") {
      root.tapeCycles = next.tapeCycles
      root.tapeAnchorMs = Date.now()
      root.tapeWherePending = false
    }
    root.status = next
    if (root.tapeWherePending) root.maybeSyncTapeCounter()
    if (root.selectedIndex > root.items.length - 1)
      root.selectedIndex = Model.clampIndex(root.selectedIndex, root.items.length)
  }

  function plain(value, cap) {
    var text = String(value || "").replace(/[<>&]/g, "")
    if (cap && text.length > cap) text = text.substring(0, cap)
    return text
  }

  function ctlCommand(args, outCap, errCap, termMs) {
    return ["/usr/bin/python3", "-I", "-S", root.runner,
            "--term-ms", String(termMs),
            "--kill-ms", String(root.killGraceMs),
            "--out-bytes", String(outCap),
            "--err-bytes", String(errCap),
            "--", root.ctl].concat(args)
  }

  function sendProcSignal(proc, sig) {
    if (!proc) return
    proc["signal"](sig)
  }

  function armProc(proc) {
    proc.aborting = false
    proc.abortReason = ""
    proc.startedAt = Date.now()
    proc.killAt = 0
    proc.outAcc = ""
    proc.errAcc = ""
    proc.outBytes = 0
    proc.errBytes = 0
    proc.leaderPid = proc.processId || 0
  }

  function terminateProc(proc, reason) {
    if (!proc) return
    proc.aborting = true
    proc.abortReason = reason || "controller timed out"
    proc.killAt = Date.now() + root.killGraceMs
    root.sendProcSignal(proc, 15)
  }

  function checkDeadline(proc, deadlineMs, now) {
    if (!proc) return
    if (proc.killAt > 0 && now >= proc.killAt) {
      root.sendProcSignal(proc, 9)
      proc.killAt = 0
      return
    }
    if (!proc.running) return
    if (proc.killAt === 0 && proc.startedAt > 0 && (now - proc.startedAt) >= deadlineMs)
      root.terminateProc(proc, "controller timed out")
  }

  function onProcChunk(proc, data, isErr) {
    if (!proc || proc.aborting) return
    var chunk = String(data || "")
    var n = chunk.length
    if (isErr) {
      proc.errBytes += n
      if (proc.errAcc.length < proc.errCap)
        proc.errAcc += chunk.substring(0, proc.errCap - proc.errAcc.length)
      if (proc.errBytes > proc.errCap)
        root.terminateProc(proc, "controller error output too large")
    } else {
      proc.outBytes += n
      if (proc.outAcc.length < proc.outCap)
        proc.outAcc += chunk.substring(0, proc.outCap - proc.outAcc.length)
      if (proc.outBytes > proc.outCap)
        root.terminateProc(proc, "controller output too large")
    }
  }

  function applyAbortError(proc) {
    if (proc && proc.aborting && proc.abortReason)
      root.lastError = root.plain(proc.abortReason, 240)
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function runCtl(args, isLaunch) {
    if (root.busy || actionProc.running) return
    root.lastError = ""
    root.busy = true
    root.pendingLaunch = isLaunch === true
    actionProc.command = root.ctlCommand(args, root.ctlOutputCap, root.ctlErrorCap, root.actionDeadlineMs)
    actionProc.running = true
  }

  function setPref(key, value) {
    runCtl(["set", String(key), String(value)])
  }

  function launchPath(path) {
    if (!path) runCtl(["play-last"], true)
    else runCtl(["launch", String(path)], true)
  }

  function launchBasic() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    runCtl(["basic"], true)
  }

  function togglePower() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    if (root.isPlaying) runCtl(["power"])
    else runCtl(["power"], true)
  }

  function resetEmu() {
    if (!root.isPlaying) return
    root.tapePlayDown = false
    root.tapeRecordArmed = false
    root.noteTapeMotion("stop")
    runCtl(["reset"])
  }

  function tapeElapsedSeconds() {
    if (!(root.tapeAnchorMs > 0) || root.isPaused || root.tapeMotion === "stop") return 0
    return Math.max(0, (Date.now() - root.tapeAnchorMs) / 1000)
  }

  function noteTapeMotion(motion) {
    root.tapeCycles = Model.advanceTapeCycles(root.tapeCycles, root.tapeElapsedSeconds(), root.tapeMotion, root.status.video)
    root.tapeAnchorMs = Date.now()
    root.tapeMotion = motion
    root.tapeTick = root.tapeTick + 1
  }

  function tapeCounterLabel() {
    if (root.tapeTick < 0) return "000"
    if (!Model.isTap(root.status.tape)) return "---"
    if (!root.isPlaying) return "000"
    return Model.formatTapeCounter(root.tapeCycles, root.tapeElapsedSeconds(), root.tapeMotion, root.status.video)
  }

  // The remote monitor freezes VICE while connected, so this runs once when
  // the panel opens rather than on a timer. Play, Stop, Rewind, and Reset
  // read the position in the monitor session they already open.
  function syncTapeCounter() {
    if (!root.isPlaying || !Model.isTap(root.status.tape)) return
    if (root.busy || actionProc.running || counterProc.running) return
    counterProc.command = root.ctlCommand(["tape-where"], root.ctlOutputCap, root.ctlErrorCap, root.statusDeadlineMs)
    counterProc.running = true
  }

  function maybeSyncTapeCounter() {
    if (!root.tapeWherePending || !root.opened) return
    if (root.busy || actionProc.running || counterProc.running) return
    root.tapeWherePending = false
    root.syncTapeCounter()
  }

  function togglePause() {
    if (!root.isPlaying) return
    runCtl(["pause"])
  }

  function loadAndRun() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    if (root.status.drive8) {
      launchPath(root.status.drive8)
      return
    }
    browseFor("launch")
  }

  function loadTape() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    if (root.status.tape) {
      runCtl(["launch-tape"], true)
      return
    }
    browseFor("launchTape")
  }

  function ejectDrive8() {
    if (!root.status.drive8) return
    runCtl(["eject"])
  }

  function attachDrive8() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    browseFor("drive8")
  }

  function ejectTape() {
    if (!root.status.tape) return
    runCtl(["eject-tape"])
  }

  function attachTape() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    browseFor("tape")
  }

  function blankDrive8() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    browseFor("blankDisk")
  }

  function blankTape() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    browseFor("blankTape")
  }

  function tapeControl(action) {
    if (!root.tapeDeckReady) return
    if (action === "record") {
      if (!Model.isTap(root.status.tape)) return
      if (root.tapeRecordArmed) {
        root.tapeRecordArmed = false
        root.tapePlayDown = false
        root.noteTapeMotion("stop")
        runCtl(["tape-ctrl", "stop"])
      } else {
        // Record holds the record key down and presses Play.
        root.tapeRecordArmed = true
        root.tapePlayDown = true
        root.noteTapeMotion("play")
        runCtl(["tape-ctrl", "record"])
      }
      return
    }
    if (action === "play") {
      root.tapePlayDown = true
      root.noteTapeMotion("play")
      if (root.tapeRecordArmed) runCtl(["tape-ctrl", "record"])
      else runCtl(["tape-ctrl", "play"])
      return
    }
    root.tapePlayDown = false
    root.tapeRecordArmed = false
    root.noteTapeMotion(action === "rewind" ? "rewind" : "stop")
    runCtl(["tape-ctrl", action])
  }

  function ejectCart() {
    if (!root.status.cart) return
    runCtl(["eject-cart"])
  }

  function attachCart() {
    if (!root.emulatorFound) {
      runCtl(["install-emu"])
      return
    }
    browseFor("cart")
  }

  function quitEmu() {
    runCtl(["quit"])
  }

  function browseFor(mode) {
    if (browseProc.running || browseStartTimer.running) return
    root.lastError = ""
    root.browseThen = mode
    root.pendingReopen = false
    if (mode === "drive8") browseProc.command = root.ctlCommand(["browse", "--disks"], root.browseOutputCap, root.ctlErrorCap, root.browseDeadlineMs)
    else if (mode === "blankDisk") browseProc.command = root.ctlCommand(["browse", "--new-disk"], root.browseOutputCap, root.ctlErrorCap, root.browseDeadlineMs)
    else if (mode === "tape" || mode === "launchTape") browseProc.command = root.ctlCommand(["browse", "--tapes"], root.browseOutputCap, root.ctlErrorCap, root.browseDeadlineMs)
    else if (mode === "blankTape") browseProc.command = root.ctlCommand(["browse", "--new-tape"], root.browseOutputCap, root.ctlErrorCap, root.browseDeadlineMs)
    else if (mode === "cart") browseProc.command = root.ctlCommand(["browse", "--carts"], root.browseOutputCap, root.ctlErrorCap, root.browseDeadlineMs)
    else browseProc.command = root.ctlCommand(["browse"], root.browseOutputCap, root.ctlErrorCap, root.browseDeadlineMs)
    // The panel is a layer-shell overlay, so zenity cannot stack above it.
    if (root.opened) root.close()
    browseStartTimer.restart()
  }

  function itemKind(index) {
    if (index < 0 || index >= items.length) return ""
    return items[index].kind
  }

  function indexOfKind(kind) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].kind === kind) return i
    }
    return -1
  }

  function hasCursorKind(kind) {
    return cursorActive && itemKind(selectedIndex) === kind
  }

  function moveCursor(delta) {
    selectedIndex = Model.clampIndex(selectedIndex + delta, items.length)
    cursorActive = true
  }

  function activateCursor() {
    if (!cursorActive) return
    var kind = itemKind(selectedIndex)
    if (kind === "drive8") attachDrive8()
    else if (kind === "blankDisk") blankDrive8()
    else if (kind === "eject") ejectDrive8()
    else if (kind === "tape") attachTape()
    else if (kind === "blankTape") blankTape()
    else if (kind === "ejectTape") ejectTape()
    else if (kind === "tapePlay") tapeControl("play")
    else if (kind === "tapeRecord") tapeControl("record")
    else if (kind === "tapeStop") tapeControl("stop")
    else if (kind === "tapeRewind") tapeControl("rewind")
    else if (kind === "cart") attachCart()
    else if (kind === "ejectCart") ejectCart()
    else if (kind === "play") loadAndRun()
    else if (kind === "playTape") loadTape()
    else if (kind === "power") togglePower()
    else if (kind === "pause") togglePause()
    else if (kind === "reset") resetEmu()
    else if (kind === "joystick") joystickBox.toggle()
    else if (kind === "port") setPref("joystickPort", Model.nextPort(status.joystickPort))
    else if (kind === "video") setPref("video", Model.nextVideo(status.video))
    else if (kind === "fullscreen") setPref("windowMode", "fullscreen")
    else if (kind === "floating") setPref("windowMode", "floating")
  }

  function focusKind(kind) {
    cursorActive = true
    var idx = indexOfKind(kind)
    if (idx >= 0) selectedIndex = idx
  }

  Component.onCompleted: {
    refresh()
    ensureProc.running = true
  }

  Component.onDestruction: {
    root.terminateProc(statusProc, "plugin unloading")
    root.terminateProc(actionProc, "plugin unloading")
    root.terminateProc(browseProc, "plugin unloading")
    root.terminateProc(ensureProc, "plugin unloading")
    root.terminateProc(counterProc, "plugin unloading")
  }

  onOpenedChanged: {
    if (opened) {
      root.tapeWherePending = true
      refresh()
      cursorActive = false
      selectedIndex = 0
    }
  }

  onIsPausedChanged: {
    if (!(root.tapeAnchorMs > 0)) return
    if (root.isPaused) {
      var seconds = Math.max(0, (Date.now() - root.tapeAnchorMs) / 1000)
      root.tapeCycles = Model.advanceTapeCycles(root.tapeCycles, seconds, root.tapeMotion, root.status.video)
    }
    root.tapeAnchorMs = Date.now()
    root.tapeTick = root.tapeTick + 1
  }

  Timer {
    interval: 2500
    running: root.opened || root.isPlaying
    repeat: true
    onTriggered: if (!root.busy && !statusProc.running) root.refresh()
  }

  Timer {
    interval: 200
    repeat: true
    running: root.opened && root.isPlaying && root.tapeMotion !== "stop" && !root.isPaused
    onTriggered: root.tapeTick = root.tapeTick + 1
  }

  Timer {
    id: browseStartTimer
    interval: 120
    repeat: false
    onTriggered: browseProc.running = true
  }

  Timer {
    id: procWatchdog
    interval: 250
    repeat: true
    running: statusProc.running || actionProc.running || browseProc.running || ensureProc.running || counterProc.running ||
             statusProc.killAt > 0 || actionProc.killAt > 0 || browseProc.killAt > 0 || ensureProc.killAt > 0 || counterProc.killAt > 0
    onTriggered: {
      var now = Date.now()
      root.checkDeadline(statusProc, root.statusDeadlineMs, now)
      root.checkDeadline(actionProc, root.actionDeadlineMs, now)
      root.checkDeadline(browseProc, root.browseDeadlineMs, now)
      root.checkDeadline(ensureProc, root.ensureDeadlineMs, now)
      root.checkDeadline(counterProc, root.statusDeadlineMs, now)
    }
  }

  Process {
    id: statusProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    property string outAcc: ""
    property string errAcc: ""
    property int outBytes: 0
    property int errBytes: 0
    property int outCap: root.ctlOutputCap
    property int errCap: root.ctlErrorCap
    property var leaderPid: 0
    clearEnvironment: true
    environment: root.ctlEnv
    command: root.ctlCommand(["status"], root.ctlOutputCap, root.ctlErrorCap, root.statusDeadlineMs)
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(statusProc, data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(statusProc, data, true) }
    }
    onStarted: root.armProc(statusProc)
    onExited: {
      if (statusProc.aborting) return
      root.ingest(statusProc.outAcc)
    }
  }

  Process {
    id: ensureProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    property string outAcc: ""
    property string errAcc: ""
    property int outBytes: 0
    property int errBytes: 0
    property int outCap: root.ctlOutputCap
    property int errCap: root.ctlErrorCap
    property var leaderPid: 0
    clearEnvironment: true
    environment: root.ctlEnv
    command: root.ctlCommand(["ensure-rules"], root.ctlOutputCap, root.ctlErrorCap, root.ensureDeadlineMs)
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(ensureProc, data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(ensureProc, data, true) }
    }
    onStarted: root.armProc(ensureProc)
  }

  Process {
    id: counterProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    property string outAcc: ""
    property string errAcc: ""
    property int outBytes: 0
    property int errBytes: 0
    property int outCap: root.ctlOutputCap
    property int errCap: root.ctlErrorCap
    property var leaderPid: 0
    clearEnvironment: true
    environment: root.ctlEnv
    command: root.ctlCommand(["tape-where"], root.ctlOutputCap, root.ctlErrorCap, root.statusDeadlineMs)
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(counterProc, data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(counterProc, data, true) }
    }
    onStarted: root.armProc(counterProc)
    onExited: {
      if (counterProc.aborting) return
      var raw = String(counterProc.outAcc || "").trim()
      if (raw.charAt(0) === "{") root.ingest(raw)
    }
  }

  Process {
    id: actionProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    property string outAcc: ""
    property string errAcc: ""
    property int outBytes: 0
    property int errBytes: 0
    property int outCap: root.ctlOutputCap
    property int errCap: root.ctlErrorCap
    property var leaderPid: 0
    clearEnvironment: true
    environment: root.ctlEnv
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(actionProc, data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(actionProc, data, true) }
    }
    onStarted: root.armProc(actionProc)
    onExited: function(exitCode) {
      root.busy = false
      var launch = root.pendingLaunch
      var reopen = root.pendingReopen
      root.pendingLaunch = false
      root.pendingReopen = false
      if (actionProc.aborting) {
        root.applyAbortError(actionProc)
        return
      }
      var raw = String(actionProc.outAcc || "").trim()
      if (raw.charAt(0) === "{") root.ingest(raw)
      var err = String(actionProc.errAcc || "").trim()
      if (err) root.lastError = root.plain(err.replace(/^omarchy64-ctl: /, "").replace(/^omarchy64-run: /, ""), 240)
      if (launch && Number(exitCode) === 0) {
        root.close()
        return
      }
      root.refresh()
      if (reopen) Qt.callLater(function() { root.open() })
    }
  }

  Process {
    id: browseProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    property string outAcc: ""
    property string errAcc: ""
    property int outBytes: 0
    property int errBytes: 0
    property int outCap: root.browseOutputCap
    property int errCap: root.ctlErrorCap
    property var leaderPid: 0
    clearEnvironment: true
    environment: root.ctlEnv
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(browseProc, data, false) }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.onProcChunk(browseProc, data, true) }
    }
    onStarted: root.armProc(browseProc)
    onExited: {
      if (browseProc.aborting) {
        root.applyAbortError(browseProc)
        return
      }
      var path = String(browseProc.outAcc || "").trim()
      if (!path) return
      if (path.indexOf("\n") >= 0 || path.indexOf("\0") >= 0) return
      if (path.length > root.browseOutputCap) return
      if (root.browseThen === "drive8") {
        root.pendingReopen = !root.isPlaying
        root.runCtl(["drive8", path])
      } else if (root.browseThen === "blankDisk") {
        root.pendingReopen = !root.isPlaying
        root.runCtl(["blank-disk", path])
      } else if (root.browseThen === "tape") {
        root.pendingReopen = !root.isPlaying
        root.runCtl(["tape", path])
      } else if (root.browseThen === "blankTape") {
        root.pendingReopen = !root.isPlaying
        root.runCtl(["blank-tape", path])
      } else if (root.browseThen === "launchTape") {
        root.runCtl(["launch-tape", path], true)
      } else if (root.browseThen === "cart") {
        root.pendingReopen = !root.isPlaying
        root.runCtl(["cart", path])
      } else {
        root.launchPath(path)
      }
    }
  }

  IpcHandler {
    target: "io.github.dannyowelch.omarchy64"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function launch(path: string): string {
      root.launchPath(path)
      return "ok"
    }
    function playLast(): string {
      root.launchPath("")
      return "ok"
    }
    function launchTape(): string {
      root.loadTape()
      return "ok"
    }
    function basic(): string {
      root.launchBasic()
      return "ok"
    }
    function power(): string {
      root.togglePower()
      return "ok"
    }
    function reset(): string {
      root.resetEmu()
      return "ok"
    }
    function pause(): string {
      root.togglePause()
      return "ok"
    }
    function drive8(): string {
      root.attachDrive8()
      return "ok"
    }
    function eject(): string {
      root.ejectDrive8()
      return "ok"
    }
    function blankDisk(): string {
      root.blankDrive8()
      return "ok"
    }
    function tape(): string {
      root.attachTape()
      return "ok"
    }
    function ejectTape(): string {
      root.ejectTape()
      return "ok"
    }
    function blankTape(): string {
      root.blankTape()
      return "ok"
    }
    function tapePlay(): string {
      root.tapeControl("play")
      return "ok"
    }
    function tapeRecord(): string {
      root.tapeControl("record")
      return "ok"
    }
    function tapeStop(): string {
      root.tapeControl("stop")
      return "ok"
    }
    function tapeRewind(): string {
      root.tapeControl("rewind")
      return "ok"
    }
    function cart(): string {
      root.attachCart()
      return "ok"
    }
    function ejectCart(): string {
      root.ejectCart()
      return "ok"
    }
    function quit(): string {
      root.quitEmu()
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.plain(root.isPaused ? "Omarchy64 · paused" : (root.isPlaying ? ("Omarchy64 · " + (status.running.title || "READY.")) : "Omarchy64"), 80)
    iconComponent: Component {
      Item {
        Icon64 {
          anchors.centerIn: parent
          iconSize: parent.width
          color: root.barForeground
          opacity: root.emulatorFound ? 1.0 : 0.55
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) root.launchPath("")
      else if (b === Qt.MiddleButton) {
        if (root.isPlaying) root.quitEmu()
        else root.loadAndRun()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.dropdownOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "d" || t === "D") root.attachDrive8()
        else if (t === "e" || t === "E") root.ejectDrive8()
        else if (t === "t" || t === "T") root.attachTape()
        else if (t === "y" || t === "Y") root.ejectTape()
        else if (t === "c" || t === "C") root.attachCart()
        else if (t === "x" || t === "X") root.ejectCart()
        else if (t === "l" || t === "L") root.loadAndRun()
        else if (t === "a" || t === "A") root.loadTape()
        else if (t === "b" || t === "B") root.togglePower()
        else if (t === "p" || t === "P") root.togglePause()
        else if (t === "q" || t === "Q") root.quitEmu()
        else if (t === "r" || t === "R") root.resetEmu()
        else if (t === "f" || t === "F") root.setPref("windowMode", Model.nextWindowMode(root.status.windowMode))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Omarchy64"
            meta: root.plain(Model.heroMeta(root.status), 80)
            detail: root.plain(root.emulatorFound ? Model.videoLabel(root.status) : "", 80)
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            iconOpacity: root.emulatorFound ? 1.0 : 0.55
            iconComponent: Component {
              Icon64 {
                iconSize: Style.font.display
                color: root.contentForeground
              }
            }
          }

          PanelSeparator {
            foreground: root.contentForeground
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.emulatorFound

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "VICE is not installed. The SDL2 package is the one this plugin launches:"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WrapAnywhere
              text: "omarchy pkg add vice-sdl2"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.emulatorFound

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: parent.width - blankDiskBtn.implicitWidth - ejectBtn.implicitWidth - parent.spacing * 2
                text: "Drive 8"
                bordered: true
                hasCursor: root.hasCursorKind("drive8")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("drive8") }
                onClicked: root.attachDrive8()
              }

              Button {
                id: blankDiskBtn
                text: "Blank"
                bordered: true
                hasCursor: root.hasCursorKind("blankDisk")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("blankDisk") }
                onClicked: root.blankDrive8()
              }

              Button {
                id: ejectBtn
                text: "Eject"
                bordered: true
                hasCursor: root.hasCursorKind("eject")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && root.status.drive8 !== ""
                onHovered: function(h) { if (h) root.focusKind("eject") }
                onClicked: root.ejectDrive8()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.drive8Label(root.status)
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: parent.width - blankTapeBtn.implicitWidth - ejectTapeBtn.implicitWidth - parent.spacing * 2
                text: "Tape"
                bordered: true
                hasCursor: root.hasCursorKind("tape")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("tape") }
                onClicked: root.attachTape()
              }

              Button {
                id: blankTapeBtn
                text: "Blank"
                bordered: true
                hasCursor: root.hasCursorKind("blankTape")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("blankTape") }
                onClicked: root.blankTape()
              }

              Button {
                id: ejectTapeBtn
                text: "Eject"
                bordered: true
                hasCursor: root.hasCursorKind("ejectTape")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && root.status.tape !== ""
                onHovered: function(h) { if (h) root.focusKind("ejectTape") }
                onClicked: root.ejectTape()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.tapeLabel(root.status)
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Row {
              visible: root.status.tape !== ""
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width - tapeCounterText.implicitWidth - parent.spacing
                text: "Counter"
                color: root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                verticalAlignment: Text.AlignVCenter
              }

              Text {
                id: tapeCounterText
                text: root.tapeCounterLabel()
                color: root.contentForeground
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                verticalAlignment: Text.AlignVCenter
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Record"
                bordered: true
                active: root.tapeRecordArmed
                hasCursor: root.hasCursorKind("tapeRecord")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: root.tapeDeckReady && Model.isTap(root.status.tape)
                onHovered: function(h) { if (h) root.focusKind("tapeRecord") }
                onClicked: root.tapeControl("record")
              }

              Button {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Play"
                bordered: true
                active: root.tapePlayDown
                hasCursor: root.hasCursorKind("tapePlay")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: root.tapeDeckReady
                onHovered: function(h) { if (h) root.focusKind("tapePlay") }
                onClicked: root.tapeControl("play")
              }

              Button {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Stop"
                bordered: true
                hasCursor: root.hasCursorKind("tapeStop")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: root.tapeDeckReady
                onHovered: function(h) { if (h) root.focusKind("tapeStop") }
                onClicked: root.tapeControl("stop")
              }

              Button {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Rewind"
                bordered: true
                hasCursor: root.hasCursorKind("tapeRewind")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: root.tapeDeckReady
                onHovered: function(h) { if (h) root.focusKind("tapeRewind") }
                onClicked: root.tapeControl("rewind")
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Record latches on and presses Play. Press it again to release. Blank creates a .tap, which can store a new program. Play and Record run at normal tape speed. The counter follows a .tap and returns to 000 when Reset rewinds the tape. A .t64 only loads. Stop releases the keys. LOAD TAPE still uses warp."
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: parent.width - ejectCartBtn.implicitWidth - parent.spacing
                text: "Cartridge"
                bordered: true
                hasCursor: root.hasCursorKind("cart")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("cart") }
                onClicked: root.attachCart()
              }

              Button {
                id: ejectCartBtn
                text: "Eject"
                bordered: true
                hasCursor: root.hasCursorKind("ejectCart")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && root.status.cart !== ""
                onHovered: function(h) { if (h) root.focusKind("ejectCart") }
                onClicked: root.ejectCart()
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.cartLabel(root.status)
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - parent.spacing) / 2
                text: 'Load "*",8,1'
                bordered: true
                hasCursor: root.hasCursorKind("play")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("play") }
                onClicked: root.loadAndRun()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "LOAD TAPE"
                bordered: true
                hasCursor: root.hasCursorKind("playTape")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && !browseProc.running
                onHovered: function(h) { if (h) root.focusKind("playTape") }
                onClicked: root.loadTape()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - parent.spacing * 2) / 3
                text: "Power"
                bordered: true
                active: root.isPlaying
                hasCursor: root.hasCursorKind("power")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy
                onHovered: function(h) { if (h) root.focusKind("power") }
                onClicked: root.togglePower()
              }

              Button {
                width: (parent.width - parent.spacing * 2) / 3
                text: "Pause"
                bordered: true
                active: root.isPaused
                hasCursor: root.hasCursorKind("pause")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && root.isPlaying
                onHovered: function(h) { if (h) root.focusKind("pause") }
                onClicked: root.togglePause()
              }

              Button {
                width: (parent.width - parent.spacing * 2) / 3
                text: "Reset"
                bordered: true
                hasCursor: root.hasCursorKind("reset")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy && root.isPlaying
                onHovered: function(h) { if (h) root.focusKind("reset") }
                onClicked: root.resetEmu()
              }
            }

            PanelSeparator {
              foreground: root.contentForeground
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Fullscreen"
                bordered: true
                active: String(root.status.windowMode || "fullscreen") !== "floating"
                hasCursor: root.hasCursorKind("fullscreen")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy
                onHovered: function(h) { if (h) root.focusKind("fullscreen") }
                onClicked: root.setPref("windowMode", "fullscreen")
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Floating"
                bordered: true
                active: String(root.status.windowMode) === "floating"
                hasCursor: root.hasCursorKind("floating")
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy
                onHovered: function(h) { if (h) root.focusKind("floating") }
                onClicked: root.setPref("windowMode", "floating")
              }
            }
          }

          PanelSeparator {
            visible: root.emulatorFound
            foreground: root.contentForeground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.emulatorFound
            opacity: root.busy ? 0.7 : 1.0

            PanelSectionHeader {
              text: "CONTROLS"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Dropdown {
              id: joystickBox
              width: parent.width
              label: "Joystick"
              value: String(root.status.joystick || "auto")
              options: Model.joystickOptions(root.status)
              hasCursor: root.hasCursorKind("joystick")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onHovered: function(h) { if (h) root.focusKind("joystick") }
              onChanged: function(v) { root.setPref("joystick", v) }
            }

            Row {
              width: parent.width
              spacing: Style.space(12)

              Column {
                id: portCol
                width: (parent.width - parent.spacing * 2 - 1) / 2
                spacing: Style.spacing.labelGap

                Text {
                  textFormat: Text.PlainText
                  text: "C64 PORT"
                  color: root.contentDim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                ButtonGroup {
                  width: parent.width
                  options: Model.portOptions()
                  value: String(root.status.joystickPort)
                  cursorIndex: root.hasCursorKind("port") ? 0 : -1
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  focusable: false
                  onHovered: function(index, h) { if (h) root.focusKind("port") }
                  onChanged: function(v) { root.setPref("joystickPort", v) }
                }
              }

              Rectangle {
                width: 1
                height: Math.max(portCol.implicitHeight, videoCol.implicitHeight)
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
              }

              Column {
                id: videoCol
                width: portCol.width
                spacing: Style.spacing.labelGap

                Text {
                  textFormat: Text.PlainText
                  text: "VIDEO"
                  color: root.contentDim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                ButtonGroup {
                  width: parent.width
                  options: Model.videoOptions()
                  value: String(root.status.video || "pal")
                  cursorIndex: root.hasCursorKind("video") ? 0 : -1
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  focusable: false
                  onHovered: function(index, h) { if (h) root.focusKind("video") }
                  onChanged: function(v) { root.setPref("video", v) }
                }
              }
            }

          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.emulatorFound

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.lastError !== ""
              wrapMode: Text.WordWrap
              text: root.plain(root.lastError, 240)
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              maximumLineCount: 4
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Drive 8, Tape, and Cartridge stay inserted. Blank creates a new disk or tape and inserts it. Load runs a disk. LOAD TAPE autostarts the cassette. Play, Record, Stop, and Rewind run the datasette while VICE is on. Power starts or stops VICE. Pause and Reset apply while it is running. Fullscreen uses workspace 64; Floating keeps a window on the current workspace. Pads use stick or D-pad plus fire; keyboard is arrows and Space."
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
