import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Acer keyboard backlight control: brightness (0-100) and static RGB color
// (0-255 per channel) written to the facer kernel module char devices.
// The devices are write-only, so state lives in state.json (written by the
// bundled kbd-rgb helper) and is the source of truth for the UI.
Panel {
  id: root
  moduleName: "kshatriya-abhay.acer-keyboard"
  ipcTarget: "kshatriya-abhay.acer-keyboard"

  property int brightnessPercent: 100
  property int red: 255
  property int green: 255
  property int blue: 255
  property string hexValue: Model.rgbToHex(root.red, root.green, root.blue)

  // Power toggle state. Turning the switch off writes brightness 0 but keeps
  // the last non-zero brightness so flipping it back on restores it. Both are
  // persisted through kbd-rgb so the state survives shell/plugin restarts.
  property bool poweredOn: true
  property int lastBrightness: 100

  // Whether the facer module + device nodes are present (checked via
  // `kbd-rgb status`). When false, the panel shows a warning banner and all
  // controls are disabled so nothing attempts to write to missing devices.
  property bool available: true
  property string availabilityIssue: ""

  // Active animation mode and its parameters (persisted via kbd-rgb).
  property string mode: "static"
  property int speed: 4
  property int direction: 1

  // Per-zone color state (static only): the zone button the edit happened on
  // ("all" | "1" | "2" | "3" | "4") and the four [r,g,b] triplets. In "all" an
  // edit writes every zone; otherwise only the selected zone changes.
  property string zone: "all"
  property var zoneColors: [[255, 255, 255], [255, 255, 255], [255, 255, 255], [255, 255, 255]]

  // Propagate channel edits into the zone table (see syncZoneColor below).
  onRedChanged: root.syncZoneColor()
  onGreenChanged: root.syncZoneColor()
  onBlueChanged: root.syncZoneColor()

  property bool applyQueued: false
  property bool restored: false
  property real wheelAccumulator: 0

  property string focusSection: "brightness"
  property int selectedIndex: -1
  property bool cursorActive: false

  readonly property var visibleSections: root.computeSections()
  readonly property bool headerHasCursor: root.cursorActive && root.focusSection === "header"

  function helperPath() {
    return String(Qt.resolvedUrl("kbd-rgb")).replace("file://", "")
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
    if (!stateProc.running) stateProc.running = true
  }

  // ---- apply pipeline -----------------------------------------------------
  function apply() {
    if (!root.available) return
    if (applyProc.running) {
      root.applyQueued = true
      return
    }
    root.applyQueued = false
    applyProc.command = [root.helperPath(), "set",
      root.mode,
      String(root.brightnessPercent), String(root.red), String(root.green), String(root.blue),
      String(root.speed), String(root.direction),
      root.poweredOn ? "1" : "0", String(root.lastBrightness),
      root.zone, root.zonesString()]
    applyProc.running = true
  }

  function queueApply() {
    commitTimer.restart()
  }

  // Any direct brightness change while the keyboard is switched off turns it
  // back on — the user clearly wants light.
  function userSetBrightness(value) {
    if (!root.available) return
    var v = Model.clampBrightness(value)
    if (v > 0 && !root.poweredOn) root.poweredOn = true
    root.brightnessPercent = v
  }

  function previewBrightness(value) {
    root.userSetBrightness(value)
    root.queueApply()
  }

  // Power switch: off writes brightness 0, on restores the previous level.
  function togglePower() {
    if (!root.available) return
    if (root.poweredOn) {
      if (root.brightnessPercent > 0) root.lastBrightness = root.brightnessPercent
      root.brightnessPercent = 0
      root.poweredOn = false
    } else {
      if (root.lastBrightness <= 0) root.lastBrightness = 100
      root.brightnessPercent = root.lastBrightness
      root.poweredOn = true
    }
    root.apply()
  }

  // ---- color field sync ---------------------------------------------------
  // Channels -> hex is live: the hex field's text is bound to hexValue
  // (self-guarded so an active edit isn't clobbered). Hex -> channels happens
  // on commit (editing finished), so typing a partial hex never fights the
  // fields. NumberFields are kept live purely by their `value:
  // root.red|green|blue` bindings — never write spin.value imperatively, that
  // severs the binding.
  function commitHex(raw) {
    if (!root.available) return
    var rgb = Model.hexToRgb(raw)
    if (rgb) {
      root.red = rgb.r
      root.green = rgb.g
      root.blue = rgb.b
    }
    commitTimer.stop()
    root.apply()
  }

  function colorFieldAt(index) {
    if (index === 0) return redNum.field
    if (index === 1) return greenNum.field
    if (index === 2) return blueNum.field
    if (index === 3) return hexField
    return null
  }

  // h/l adjusts the channel slider the cursor is on (indices 0-2); the hex
  // row has nothing to adjust.
  function adjustChannel(delta) {
    if (root.focusSection !== "color") return
    if (root.selectedIndex < 0 || root.selectedIndex > 2) return
    var v = 0
    if (root.selectedIndex === 0) v = Model.clampByte(root.red + delta)
    else if (root.selectedIndex === 1) v = Model.clampByte(root.green + delta)
    else v = Model.clampByte(root.blue + delta)
    if (root.selectedIndex === 0) root.red = v
    else if (root.selectedIndex === 1) root.green = v
    else root.blue = v
    root.queueApply()
  }

  // ---- modes ---------------------------------------------------------------
  // Sections shown depend on the active mode: speed only for animations,
  // direction only for wave/shifting, color hidden where the module ignores it.
  function computeSections() {
    var s = ["brightness", "mode"]
    if (root.mode === "static") s.push("zones")
    if (Model.isDynamic(root.mode)) s.push("speed")
    if (Model.usesDirection(root.mode)) s.push("direction")
    if (Model.usesColor(root.mode)) s.push("color")
    return s
  }

  function setMode(name) {
    if (name === root.mode) return
    root.mode = name
    // Returning to static: show the selected zone's color so the sliders match
    // what's actually on the keyboard ("all" keeps the current edit color).
    if (name === "static" && root.zone !== "all") {
      var idx = Number(root.zone) - 1
      root.red = root.zoneColors[idx][0]
      root.green = root.zoneColors[idx][1]
      root.blue = root.zoneColors[idx][2]
    }
    root.clampCursor()
    root.apply()
  }

  // ---- zones ---------------------------------------------------------------
  // Keep the per-zone table in step with the editable channels: editing in
  // "all" writes every zone, editing in zone N writes only zone N. Entering a
  // zone does NOT clobber the others because setZone() only changes the channels
  // (which sync back to the same zone they were read from).
  function syncZoneColor() {
    if (root.zone === "all") {
      root.zoneColors = [
        [root.red, root.green, root.blue],
        [root.red, root.green, root.blue],
        [root.red, root.green, root.blue],
        [root.red, root.green, root.blue]
      ]
    } else {
      var idx = Number(root.zone) - 1
      var c = root.zoneColors
      var copy = c.slice()
      copy[idx] = [root.red, root.green, root.blue]
      root.zoneColors = copy
    }
  }

  function zonesString() {
    var parts = []
    for (var i = 0; i < root.zoneColors.length; i++) {
      var t = root.zoneColors[i]
      parts.push(String(t[0]) + "," + String(t[1]) + "," + String(t[2]))
    }
    return parts.join(";")
  }

  function setZone(name) {
    if (name === root.zone) return
    root.zone = name
    if (name !== "all") {
      var idx = Number(name) - 1
      root.red = root.zoneColors[idx][0]
      root.green = root.zoneColors[idx][1]
      root.blue = root.zoneColors[idx][2]
    }
    root.apply()
  }

  // h/l moves within the 1x5 zone row; Enter activates the focused zone.
  function adjustZone(delta) {
    if (root.focusSection !== "zones") return
    var t = root.selectedIndex + delta
    if (t >= 0 && t < Model.ZONES.length) root.selectedIndex = t
  }

  // h/l moves within the 2x3 grid.
  function adjustMode(delta) {
    if (root.focusSection !== "mode") return
    var t = root.selectedIndex + delta
    if (t >= 0 && t < Model.MODES.length) root.selectedIndex = t
  }

  function adjustSpeed(delta) {
    if (root.focusSection !== "speed") return
    root.speed = Model.clampSpeed(root.speed + delta)
    root.apply()
  }

  // Direction has two values (1: right->left, 2: left->right); any horizontal
  // key toggles between them.
  function adjustDirection() {
    if (root.focusSection !== "direction") return
    root.direction = root.direction === 1 ? 2 : 1
    root.apply()
  }

  // ---- keyboard cursor model ----------------------------------------------
  function sectionCount(section) {
    if (section === "brightness") return 0  // single slider sentinel at -1
    if (section === "mode") return Model.MODES.length
    if (section === "zones") return Model.ZONES.length
    if (section === "speed") return 0
    if (section === "direction") return 0
    if (section === "color") return 4       // R, G, B, hex
    return 0
  }

  function sectionIsSingleRow(section) {
    return section === "brightness" || section === "speed" || section === "direction"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness") return -1
    if (section === "speed") return -1
    if (section === "direction") return -1
    return 0
  }

  function moveCursor(delta) {
    if (root.focusSection === "header") {
      if (delta > 0) {
        root.focusSection = root.visibleSections[0]
        root.selectedIndex = root.sectionFirstIndex(root.visibleSections[0])
      }
      return
    }
    // The mode grid is 2 rows of 3: j/k jump a whole row. At the top/bottom
    // edge the grid can't move further, so the move becomes a section change.
    var forceExit = false
    if (root.focusSection === "mode") {
      var gridTarget = root.selectedIndex + delta * 3
      if (gridTarget >= 0 && gridTarget < Model.MODES.length) {
        root.selectedIndex = gridTarget
        return
      }
      forceExit = true
    }
    var sections = root.visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(root.focusSection)
    if (sIdx < 0) {
      root.focusSection = sections[0]
      root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      return
    }
    var inSingleRow = root.sectionIsSingleRow(root.focusSection) || forceExit
    var max = inSingleRow ? 0 : root.sectionCount(root.focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && root.selectedIndex < max) { root.selectedIndex = root.selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        root.focusSection = sections[sIdx + 1]
        root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      }
    } else {
      if (!inSingleRow && root.selectedIndex > 0) { root.selectedIndex = root.selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        root.focusSection = prev
        root.selectedIndex = root.sectionIsSingleRow(prev) ? root.sectionFirstIndex(prev) : root.sectionCount(prev) - 1
      } else {
        root.focusSection = "header"
      }
    }
  }

  function adjustBrightness(delta) {
    if (root.focusSection !== "brightness") return
    root.previewBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (root.focusSection === "header") { root.togglePower(); return }
    if (root.focusSection === "mode") {
      root.setMode(Model.MODES[root.selectedIndex].name)
      return
    }
    if (root.focusSection === "zones") {
      root.setZone(Model.ZONES[root.selectedIndex].value)
      return
    }
    if (root.focusSection !== "color") return
    var target = root.colorFieldAt(root.selectedIndex)
    if (target) target.forceActiveFocus()
  }

  function clampCursor() {
    if (root.focusSection === "header") return
    var sections = root.visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(root.focusSection) < 0) {
      root.focusSection = sections[0]
      root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      return
    }
    var count = root.sectionCount(root.focusSection)
    if (root.sectionIsSingleRow(root.focusSection)) {
      root.selectedIndex = -1
      return
    }
    if (root.selectedIndex > count - 1) root.selectedIndex = count - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "keyboard",
      value: percent
    }))
  }

  // True when the user is editing a text field, which suspends the panel's
  // keyboard navigation so typed keys reach the field.
  readonly property bool editingField:
    redNum.field && redNum.field.activeFocus ||
    greenNum.field && greenNum.field.activeFocus ||
    blueNum.field && blueNum.field.activeFocus ||
    hexField && hexField.activeFocus

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: root.refresh()

  onOpenedChanged: {
    if (opened) {
      root.refresh()
      root.focusSection = "brightness"
      root.selectedIndex = -1
      root.cursorActive = false
    }
  }

  Process {
    id: stateProc
    command: [root.helperPath(), "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = Model.parseState(text)
        // Load the zone table before the channels so syncZoneColor writes
        // back into the persisted per-zone colors, not the defaults.
        root.zone = state.zone
        root.zoneColors = state.zones
        root.brightnessPercent = state.brightness
        root.red = state.r
        root.green = state.g
        root.blue = state.b
        root.poweredOn = state.poweredOn
        root.lastBrightness = state.lastBrightness
        root.mode = state.mode
        root.speed = state.speed
        root.direction = state.direction
        root.clampCursor()
      }
    }
  }

  Process {
    id: statusProc
    command: [root.helperPath(), "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out === "module-missing") {
          root.available = false
          root.availabilityIssue = "Acer keyboard kernel module (facer) not found. Install acer-predator-turbo-and-rgb-keyboard-linux-module and load it."
        } else if (out === "devices-missing") {
          root.available = false
          root.availabilityIssue = "facer is loaded but the /dev/acer-gkbbl-* device nodes are missing. Check module parameters or udev rules."
        } else {
          root.available = true
          root.availabilityIssue = ""
        }
        // Restore the last applied color/brightness on plugin load, but only
        // once availability is known (and only when devices exist).
        if (root.setting("applyOnStart", true) && !root.restored) {
          root.restored = true
          if (root.available) root.apply()
        }
      }
    }
  }

  Process {
    id: applyProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.applyQueued) root.apply()
    }
  }

  Timer {
    id: commitTimer
    interval: 200
    repeat: false
    onTriggered: root.apply()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.togglePower()
      } else {
        root.toggle()
      }
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.userSetBrightness(root.brightnessPercent + wheel.steps * 5)
      root.apply()
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingField

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "color") root.adjustChannel(dx * 5)
          else if (root.focusSection === "mode") root.adjustMode(dx)
          else if (root.focusSection === "zones") root.adjustZone(dx)
          else if (root.focusSection === "speed") root.adjustSpeed(dx)
          else if (root.focusSection === "direction") root.adjustDirection()
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Warning banner (module / devices missing) ----------
          Rectangle {
            id: warningBanner
            visible: !root.available
            width: parent.width
            implicitHeight: warningMessage.implicitHeight + Style.space(18)
            radius: Style.cornerRadius
            color: Util.alpha(Color.urgent, 0.10)
            border.color: Util.alpha(Color.urgent, 0.45)
            border.width: 1

            Row {
              id: warningRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(10)

              Text {
                id: warningIcon
                text: "⚠"
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: warningMessage
                text: root.availabilityIssue !== ""
                  ? root.availabilityIssue
                  : "Acer keyboard control is unavailable."
                color: Color.urgent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                width: warningRow.width - warningIcon.width - warningRow.spacing
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          // ---------- Hero: keyboard icon · title/status · power switch ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            Text {
              id: heroIcon
              text: "󰌌"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.poweredOn ? 1.0 : 0.5
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter

              Behavior on opacity {
                NumberAnimation { duration: 150 }
              }
            }

            ToggleSwitch {
              id: powerSwitch
              checked: root.poweredOn
              enabled: root.available
              hasCursor: root.headerHasCursor
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function(on) {
                if (!on) return
                root.cursorActive = true
                root.focusSection = "header"
              }
              onToggled: root.togglePower()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.poweredOn ? "Turn off keyboard backlight" : "Turn on keyboard backlight"
                fontFamily: root.bar.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Keyboard"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: Model.modeLabel(root.mode).toUpperCase() + " · " + root.hexValue.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSliderFixed {
                id: brightnessSlider
                bar: root.bar
                enabled: root.available
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 100
                step: 1
                integer: true
                value: root.brightnessPercent
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  commitTimer.stop()
                  root.userSetBrightness(v)
                  root.apply()
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Mode ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(modeHeader.implicitHeight, modeValue.implicitHeight)

              PanelSectionHeader {
                id: modeHeader
                text: "MODE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: modeValue
                text: Model.modeLabel(root.mode)
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: modeGrid
              width: parent.width
              height: modeGridContent.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "mode"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(modeGrid)
              foreground: root.bar.foreground
              outline: true

              Grid {
                id: modeGridContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                columns: 3
                rows: 2
                columnSpacing: Style.space(8)
                rowSpacing: Style.space(8)

                Repeater {
                  model: Model.MODES
                  delegate: Button {
                    id: modeButton
                    required property var modelData
                    required property int index

                    width: Math.floor((modeGridContent.width - modeGridContent.columnSpacing * 2) / 3)
                    text: modeButton.modelData.label
                    selected: modeButton.modelData.name === root.mode
                    hasCursor: root.cursorActive && root.focusSection === "mode" && root.selectedIndex === index
                    enabled: root.available
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.setMode(modeButton.modelData.name)
                    onHovered: function(on) {
                      if (!on) return
                      root.cursorActive = true
                      root.focusSection = "mode"
                      root.selectedIndex = index
                    }
                  }
                }
              }
            }
          }

          // ---------- Zones (static) ----------
          Column {
            id: zoneSection
            visible: root.mode === "static"
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(zoneHeader.implicitHeight, zoneValue.implicitHeight)

              PanelSectionHeader {
                id: zoneHeader
                text: "ZONES"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: zoneValue
                text: root.zone === "all" ? "All" : "Zone " + root.zone
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: zoneRow
              width: parent.width
              height: zoneButtons.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "zones"
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(zoneRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: zoneButtons
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Repeater {
                  model: Model.ZONES
                  delegate: Button {
                    id: zoneButton
                    required property var modelData
                    required property int index

                    width: Math.floor((zoneButtons.width - zoneButtons.spacing * (Model.ZONES.length - 1)) / Model.ZONES.length)
                    text: zoneButton.modelData.label
                    selected: zoneButton.modelData.value === root.zone
                    hasCursor: root.cursorActive && root.focusSection === "zones" && root.selectedIndex === index
                    enabled: root.available
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.setZone(zoneButton.modelData.value)
                    onHovered: function(on) {
                      if (!on) return
                      root.cursorActive = true
                      root.focusSection = "zones"
                      root.selectedIndex = index
                    }
                  }
                }
              }
            }
          }

          // ---------- Speed (animations) ----------
          Column {
            id: speedSection
            visible: Model.isDynamic(root.mode)
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(speedHeader.implicitHeight, speedValue.implicitHeight)

              PanelSectionHeader {
                id: speedHeader
                text: "SPEED"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: speedValue
                text: speedSlider.dragging ? speedSlider.liveValue : root.speed
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: speedRow
              width: parent.width
              height: speedSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "speed" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(speedRow)
              foreground: root.bar.foreground
              outline: true

              PanelSliderFixed {
                id: speedSlider
                bar: root.bar
                enabled: root.available
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 9
                step: 1
                integer: true
                value: root.speed
                onMoved: function(v) { root.speed = v; root.queueApply() }
                onReleased: function(v) {
                  commitTimer.stop()
                  root.speed = v
                  root.apply()
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "speed"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Direction (wave / shifting) ----------
          Column {
            id: directionSection
            visible: Model.usesDirection(root.mode)
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(directionHeader.implicitHeight, directionValue.implicitHeight)

              PanelSectionHeader {
                id: directionHeader
                text: "DIRECTION"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: directionValue
                text: root.direction === 1 ? "Left to Right" : "Right to Left"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: directionRow
              width: parent.width
              height: directionButtons.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "direction" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(directionRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: directionButtons
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Button {
                  id: dirLeftButton
                  width: (directionButtons.width - directionButtons.spacing) / 2
                  text: "←  Right to Left"
                  selected: root.direction === 2
                  enabled: root.available
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: { root.direction = 2; root.apply() }
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.focusSection = "direction"
                    root.selectedIndex = -1
                  }
                }

                Button {
                  id: dirRightButton
                  width: (directionButtons.width - directionButtons.spacing) / 2
                  text: "Left to Right  →"
                  selected: root.direction === 1
                  enabled: root.available
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: { root.direction = 1; root.apply() }
                  onHovered: function(on) {
                    if (!on) return
                    root.cursorActive = true
                    root.focusSection = "direction"
                    root.selectedIndex = -1
                  }
                }
              }
            }
          }

          // ---------- Color (static / breath / shifting / zoom) ----------
          PanelSeparator {
            visible: Model.usesColor(root.mode)
            foreground: root.bar.foreground
          }

          Column {
            visible: Model.usesColor(root.mode)
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(colorHeader.implicitHeight, swatch.height)

              PanelSectionHeader {
                id: colorHeader
                text: "COLOR"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                id: swatch
                width: Style.space(18)
                height: Style.space(18)
                radius: Style.space(4)
                color: root.hexValue
                border.color: Qt.darker(root.bar.foreground, 1.4)
                border.width: 1
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: redRow
              width: parent.width
              height: redInner.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "color" && root.selectedIndex === 0
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(redRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: redInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(10)

                Text {
                  id: redLabel
                  text: "R"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  width: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelSliderFixed {
                  id: redSlider
                  bar: root.bar
                  enabled: root.available
                  width: Math.max(40, redInner.width - redLabel.width - redNum.width - redInner.spacing * 2)
                  minimum: 0
                  maximum: 255
                  step: 1
                  integer: true
                  value: root.red
                  anchors.verticalCenter: parent.verticalCenter
                  onMoved: function(v) { root.red = v; root.queueApply() }
                  onReleased: function(v) { commitTimer.stop(); root.red = v; root.apply() }
                }

                NumberField {
                  id: redNum
                  value: root.red
                  enabled: root.available
                  from: 0
                  to: 255
                  stepSize: 1
                  fieldWidth: Style.space(58)
                  foreground: root.bar.foreground
                  accent: Color.accent
                  fontFamily: root.bar.fontFamily
                  onModified: function(v) { root.red = v; root.queueApply() }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "color"
                  root.selectedIndex = 0
                }
              }
            }

            CursorSurface {
              id: greenRow
              width: parent.width
              height: greenInner.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "color" && root.selectedIndex === 1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(greenRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: greenInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(10)

                Text {
                  id: greenLabel
                  text: "G"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  width: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelSliderFixed {
                  id: greenSlider
                  bar: root.bar
                  enabled: root.available
                  width: Math.max(40, greenInner.width - greenLabel.width - greenNum.width - greenInner.spacing * 2)
                  minimum: 0
                  maximum: 255
                  step: 1
                  integer: true
                  value: root.green
                  anchors.verticalCenter: parent.verticalCenter
                  onMoved: function(v) { root.green = v; root.queueApply() }
                  onReleased: function(v) { commitTimer.stop(); root.green = v; root.apply() }
                }

                NumberField {
                  id: greenNum
                  value: root.green
                  enabled: root.available
                  from: 0
                  to: 255
                  stepSize: 1
                  fieldWidth: Style.space(58)
                  foreground: root.bar.foreground
                  accent: Color.accent
                  fontFamily: root.bar.fontFamily
                  onModified: function(v) { root.green = v; root.queueApply() }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "color"
                  root.selectedIndex = 1
                }
              }
            }

            CursorSurface {
              id: blueRow
              width: parent.width
              height: blueInner.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "color" && root.selectedIndex === 2
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(blueRow)
              foreground: root.bar.foreground
              outline: true

              Row {
                id: blueInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(10)

                Text {
                  id: blueLabel
                  text: "B"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  width: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelSliderFixed {
                  id: blueSlider
                  bar: root.bar
                  enabled: root.available
                  width: Math.max(40, blueInner.width - blueLabel.width - blueNum.width - blueInner.spacing * 2)
                  minimum: 0
                  maximum: 255
                  step: 1
                  integer: true
                  value: root.blue
                  anchors.verticalCenter: parent.verticalCenter
                  onMoved: function(v) { root.blue = v; root.queueApply() }
                  onReleased: function(v) { commitTimer.stop(); root.blue = v; root.apply() }
                }

                NumberField {
                  id: blueNum
                  value: root.blue
                  enabled: root.available
                  from: 0
                  to: 255
                  stepSize: 1
                  fieldWidth: Style.space(58)
                  foreground: root.bar.foreground
                  accent: Color.accent
                  fontFamily: root.bar.fontFamily
                  onModified: function(v) { root.blue = v; root.queueApply() }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "color"
                  root.selectedIndex = 2
                }
              }
            }

            CursorSurface {
              id: hexRow
              width: parent.width
              height: hexField.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "color" && root.selectedIndex === 3
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(hexRow)
              foreground: root.bar.foreground
              outline: true

              TextField {
                id: hexField
                enabled: root.available
                width: parent.width - Style.space(12)
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "#RRGGBB"
                horizontalAlignment: Text.AlignHCenter
                foreground: root.bar.foreground
                accent: Color.accent
                // Live from channels, but never clobber an in-progress edit.
                text: hexField.activeFocus ? hexField.text : root.hexValue
                onEditingFinished: root.commitHex(hexField.text)
                onAccepted: root.commitHex(hexField.text)
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "color"
                  root.selectedIndex = 3
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }
}
