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

  readonly property string pluginDir: {
    var s = String(Qt.resolvedUrl("."))
    if (s.indexOf("file://") === 0) s = s.substring(7)
    return decodeURIComponent(s.replace(/\/$/, ""))
  }
  readonly property string ctl: pluginDir + "/omarchy64-ctl"
  readonly property var items: Model.cursorItems(status)
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.4)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool emulatorFound: status.emulator && status.emulator.found
  readonly property bool isPlaying: status.running && status.running.active
  readonly property bool isPaused: root.isPlaying && status.running.paused === true
  readonly property bool dropdownOpen: joystickBox.popupOpen === true
  readonly property int ctlOutputCap: 65536
  readonly property int ctlErrorCap: 4096
  readonly property int browseOutputCap: 8192
  readonly property int statusDeadlineMs: 8000
  readonly property int ensureDeadlineMs: 8000
  readonly property int actionDeadlineMs: 30000
  readonly property int browseDeadlineMs: 300000
  readonly property int killGraceMs: 1000

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
    root.status = Model.parseStatus(text)
    if (root.selectedIndex > root.items.length - 1)
      root.selectedIndex = Model.clampIndex(root.selectedIndex, root.items.length)
  }

  function collectorBytes(collector) {
    if (!collector) return 0
    if (collector.data && collector.data.byteLength !== undefined)
      return collector.data.byteLength
    return String(collector.text || "").length
  }

  function boundedText(collector, cap) {
    var text = String((collector && collector.text) || "")
    if (text.length > cap) return text.substring(0, cap)
    return text
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
  }

  function terminateProc(proc, reason) {
    if (!proc) return
    proc.aborting = true
    proc.abortReason = reason || "controller timed out"
    if (proc.running) {
      proc.running = false
      proc.killAt = Date.now() + root.killGraceMs
    }
  }

  function killProc(proc) {
    if (!proc || !proc.running) return
    proc.aborting = true
    root.sendProcSignal(proc, 9)
  }

  function checkDeadline(proc, deadlineMs, now) {
    if (!proc || !proc.running) return
    if (proc.killAt > 0 && now >= proc.killAt) {
      root.killProc(proc)
      return
    }
    if (proc.killAt === 0 && proc.startedAt > 0 && (now - proc.startedAt) >= deadlineMs)
      root.terminateProc(proc, "controller timed out")
  }

  function checkOutputCap(proc, collector, cap, reason) {
    if (!proc || proc.aborting) return
    if (root.collectorBytes(collector) > cap)
      root.terminateProc(proc, reason || "controller output too large")
  }

  function applyAbortError(proc) {
    if (proc && proc.aborting && proc.abortReason)
      root.lastError = proc.abortReason
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function runCtl(args, isLaunch) {
    if (root.busy || actionProc.running) return
    root.lastError = ""
    root.busy = true
    root.pendingLaunch = isLaunch === true
    actionProc.command = [root.ctl].concat(args)
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
    runCtl(["reset"])
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
    if (mode === "drive8") browseProc.command = [root.ctl, "browse", "--disks"]
    else if (mode === "tape" || mode === "launchTape") browseProc.command = [root.ctl, "browse", "--tapes"]
    else if (mode === "cart") browseProc.command = [root.ctl, "browse", "--carts"]
    else browseProc.command = [root.ctl, "browse"]
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
    else if (kind === "eject") ejectDrive8()
    else if (kind === "tape") attachTape()
    else if (kind === "ejectTape") ejectTape()
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

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      selectedIndex = 0
    }
  }

  Timer {
    interval: 2500
    running: root.opened || root.isPlaying
    repeat: true
    onTriggered: if (!root.busy && !statusProc.running) root.refresh()
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
    running: statusProc.running || actionProc.running || browseProc.running || ensureProc.running
    onTriggered: {
      var now = Date.now()
      root.checkDeadline(statusProc, root.statusDeadlineMs, now)
      root.checkDeadline(actionProc, root.actionDeadlineMs, now)
      root.checkDeadline(browseProc, root.browseDeadlineMs, now)
      root.checkDeadline(ensureProc, root.ensureDeadlineMs, now)
    }
  }

  Process {
    id: statusProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    command: [root.ctl, "status"]
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: root.checkOutputCap(statusProc, this, root.ctlOutputCap, "status output too large")
      onStreamFinished: {
        if (statusProc.aborting) return
        root.ingest(root.boundedText(this, root.ctlOutputCap))
      }
    }
    onStarted: root.armProc(statusProc)
  }

  Process {
    id: ensureProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    command: [root.ctl, "ensure-rules"]
    onStarted: root.armProc(ensureProc)
  }

  Process {
    id: actionProc
    property bool aborting: false
    property string abortReason: ""
    property double startedAt: 0
    property double killAt: 0
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: root.checkOutputCap(actionProc, this, root.ctlOutputCap, "controller output too large")
      onStreamFinished: {
        if (actionProc.aborting) return
        var raw = root.boundedText(this, root.ctlOutputCap).trim()
        if (raw.charAt(0) === "{") root.ingest(raw)
      }
    }
    stderr: StdioCollector {
      waitForEnd: false
      onDataChanged: root.checkOutputCap(actionProc, this, root.ctlErrorCap, "controller error output too large")
      onStreamFinished: {
        if (actionProc.aborting) return
        var err = root.boundedText(this, root.ctlErrorCap).trim()
        if (err) root.lastError = err.replace(/^omarchy64-ctl: /, "")
      }
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
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: root.checkOutputCap(browseProc, this, root.browseOutputCap, "file chooser output too large")
      onStreamFinished: {
        if (browseProc.aborting) return
        var path = root.boundedText(this, root.browseOutputCap).trim()
        if (!path) return
        if (path.indexOf("\n") >= 0 || path.indexOf("\0") >= 0) return
        if (root.browseThen === "drive8") {
          root.pendingReopen = !root.isPlaying
          root.runCtl(["drive8", path])
        } else if (root.browseThen === "tape") {
          root.pendingReopen = !root.isPlaying
          root.runCtl(["tape", path])
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
    onStarted: root.armProc(browseProc)
    onExited: root.applyAbortError(browseProc)
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
    function tape(): string {
      root.attachTape()
      return "ok"
    }
    function ejectTape(): string {
      root.ejectTape()
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
    tooltipText: root.isPaused ? "Omarchy64 · paused" : (root.isPlaying ? ("Omarchy64 · " + (status.running.title || "READY.")) : "Omarchy64")
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
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

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
            meta: Model.heroMeta(root.status)
            detail: root.emulatorFound ? Model.videoLabel(root.status) : ""
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
              width: parent.width
              wrapMode: Text.WordWrap
              text: "VICE is not installed. The SDL2 package is the one this plugin launches:"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
            }

            Text {
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
                width: parent.width - ejectBtn.implicitWidth - parent.spacing
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
                width: parent.width - ejectTapeBtn.implicitWidth - parent.spacing
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
              width: parent.width
              text: Model.tapeLabel(root.status)
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
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
              width: parent.width
              visible: root.lastError !== ""
              wrapMode: Text.WordWrap
              text: root.lastError
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              maximumLineCount: 4
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Drive 8, Tape, and Cartridge stay inserted. Load runs a disk. LOAD TAPE autostarts the cassette. Power starts or stops VICE. Pause and Reset apply while it is running. Pads use stick or D-pad plus fire; keyboard is arrows and Space."
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
