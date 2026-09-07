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
  readonly property bool dropdownOpen: joystickBox.popupOpen === true

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
    root.status = Model.parseStatus(raw)
    if (root.selectedIndex > root.items.length - 1)
      root.selectedIndex = Model.clampIndex(root.selectedIndex, root.items.length)
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

  function quitEmu() {
    runCtl(["quit"])
  }

  function browseFor(mode) {
    if (browseProc.running || browseStartTimer.running) return
    root.lastError = ""
    root.browseThen = mode
    root.pendingReopen = false
    browseProc.command = [root.ctl, "browse", "--disks"]
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
    else if (kind === "play") loadAndRun()
    else if (kind === "basic") launchBasic()
    else if (kind === "joystick") joystickBox.toggle()
    else if (kind === "port") setPref("joystickPort", Model.nextPort(status.joystickPort))
    else if (kind === "video") setPref("video", Model.nextVideo(status.video))
    else if (kind === "quit") quitEmu()
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

  Process {
    id: statusProc
    command: [root.ctl, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingest(text)
    }
  }

  Process {
    id: ensureProc
    command: [root.ctl, "ensure-rules"]
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw.charAt(0) === "{") root.ingest(raw)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err) root.lastError = err.replace(/^omarchy64-ctl: /, "")
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      var launch = root.pendingLaunch
      var reopen = root.pendingReopen
      root.pendingLaunch = false
      root.pendingReopen = false
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim()
        if (!path) return
        if (root.browseThen === "drive8") {
          root.pendingReopen = !root.isPlaying
          root.runCtl(["drive8", path])
        } else {
          root.launchPath(path)
        }
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
    function basic(): string {
      root.launchBasic()
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
    function quit(): string {
      root.quitEmu()
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.isPlaying ? ("Omarchy64 · " + (status.running.title || "READY.")) : "Omarchy64"
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
        else if (t === "l" || t === "L") root.loadAndRun()
        else if (t === "b" || t === "B") root.launchBasic()
        else if (t === "q" || t === "Q") root.quitEmu()
        else if (t === "r" || t === "R") root.refresh()
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

            PanelSectionHeader {
              text: "C64"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

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

            Button {
              width: parent.width
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
              width: parent.width
              text: "BASIC"
              bordered: true
              hasCursor: root.hasCursorKind("basic")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: !root.busy
              onHovered: function(h) { if (h) root.focusKind("basic") }
              onClicked: root.launchBasic()
            }

            Button {
              width: parent.width
              visible: root.isPlaying
              text: "Quit VICE"
              bordered: true
              hasCursor: root.hasCursorKind("quit")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: !root.busy
              onHovered: function(h) { if (h) root.focusKind("quit") }
              onClicked: root.quitEmu()
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

            Column {
              width: parent.width
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

            Column {
              width: parent.width
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
              text: "Drive 8 sets the disk. Load runs it. BASIC starts at READY. Pads use stick or D-pad plus fire; keyboard is arrows and Space."
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
