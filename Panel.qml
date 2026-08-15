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

  property bool applyQueued: false
  property bool restored: false
  property real wheelAccumulator: 0

  property string focusSection: "brightness"
  property int selectedIndex: -1
  property bool cursorActive: false

  readonly property var visibleSections: ["brightness", "color"]
  readonly property bool headerHasCursor: root.cursorActive && root.focusSection === "header"

  function helperPath() {
    return String(Qt.resolvedUrl("kbd-rgb")).replace("file://", "")
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // ---- apply pipeline -----------------------------------------------------
  function apply() {
    if (applyProc.running) {
      root.applyQueued = true
      return
    }
    root.applyQueued = false
    applyProc.command = [root.helperPath(), "set",
      String(root.brightnessPercent), String(root.red), String(root.green), String(root.blue),
      root.poweredOn ? "1" : "0", String(root.lastBrightness)]
    applyProc.running = true
  }

  function queueApply() {
    commitTimer.restart()
  }

  // Any direct brightness change while the keyboard is switched off turns it
  // back on — the user clearly wants light.
  function userSetBrightness(value) {
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
  // Channels -> hex is live. Hex -> channels happens on commit (editing
  // finished), so typing a partial hex value never fights the fields.
  function syncHex() {
    hexField.text = root.hexValue
  }

  function syncColorFields() {
    redNum.field.value = root.red
    greenNum.field.value = root.green
    blueNum.field.value = root.blue
    root.syncHex()
  }

  function commitHex(raw) {
    var rgb = Model.hexToRgb(raw)
    if (rgb) {
      root.red = rgb.r
      root.green = rgb.g
      root.blue = rgb.b
    }
    root.syncColorFields()
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

  // ---- keyboard cursor model ----------------------------------------------
  function sectionCount(section) {
    if (section === "brightness") return 0  // single slider sentinel at -1
    if (section === "color") return 4       // R, G, B, hex
    return 0
  }

  function sectionIsSingleRow(section) {
    return section === "brightness"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness") return -1
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
    var sections = root.visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(root.focusSection)
    if (sIdx < 0) {
      root.focusSection = sections[0]
      root.selectedIndex = root.sectionFirstIndex(root.focusSection)
      return
    }
    var inSingleRow = root.sectionIsSingleRow(root.focusSection)
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

  onRedChanged: root.syncHex()
  onGreenChanged: root.syncHex()
  onBlueChanged: root.syncHex()

  Process {
    id: stateProc
    command: [root.helperPath(), "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = Model.parseState(text)
        root.brightnessPercent = state.brightness
        root.red = state.r
        root.green = state.g
        root.blue = state.b
        root.poweredOn = state.poweredOn
        root.lastBrightness = state.lastBrightness
        root.syncColorFields()
        // Restore the last applied color/brightness on plugin load.
        if (root.setting("applyOnStart", true) && !root.restored) {
          root.restored = true
          root.apply()
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
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

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
                text: "RGB · " + root.hexValue.toUpperCase()
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

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
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

          // ---------- Color ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
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

                PanelSlider {
                  id: redSlider
                  bar: root.bar
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

                PanelSlider {
                  id: greenSlider
                  bar: root.bar
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

                PanelSlider {
                  id: blueSlider
                  bar: root.bar
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
                width: parent.width - Style.space(12)
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "#RRGGBB"
                horizontalAlignment: Text.AlignHCenter
                foreground: root.bar.foreground
                accent: Color.accent
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
