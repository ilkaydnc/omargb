import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OpenRGB in the bar: a dot in the current lighting color, and a popup that
// lists every device OpenRGB sees with its mode, color, brightness and speed.
//
// This file is the bar widget. The connection itself lives in Service.qml,
// which the shell creates once per plugin; the widget reaches it through
// `bar.shell.serviceFor(id)`, so a bar on every monitor shares one bridge.
//
// Keys: j/k or arrows walk the devices, Enter expands one, h/l step its mode,
// a paints the theme accent everywhere, t toggles theme sync, o toggles
// stealth mode, r refreshes, s saves the selected device's mode, Esc closes.
Panel {
  id: root
  moduleName: "io.github.ilkaydnc.omargb"
  ipcTarget: "omargb"
  manageIpc: false

  readonly property var service: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor(root.moduleName) : null
  readonly property bool connected: service ? service.connected === true : false
  readonly property var devices: service && service.devices ? service.devices : []
  readonly property string accentHex: Model.hexOf(Color.accent)
  readonly property bool vividAccent: setting("vividAccent", true) !== false
  // The color "apply the accent" really sends; comparisons against "did the
  // user pick something other than the accent" must use the same value.
  readonly property string deviceAccent: vividAccent ? Model.ledAccent(accentHex) : accentHex
  readonly property bool themeSync: setting("themeSync", false) === true
  readonly property string summaryColor: service ? service.summaryColor : ""
  readonly property string actionError: service ? service.actionError : ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color hoverFill: Style.hoverFillFor(fg, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(fg, Color.accent)

  readonly property var swatches: Model.swatches(deviceAccent)

  // Devices switched off from here, with what to restore when they come back:
  // { "<device name>": { "mode": <index>, "color": "#rrggbb" } }. Keyed by
  // name so an index shuffle (replug, rescan) cannot relight the wrong device.
  readonly property var offMap: setting("off", ({})) || ({})

  function deviceIsOff(name) {
    return offMap[String(name)] !== undefined
  }

  // Stealth is not separate state: it is simply "every device is off", so a
  // device switched back on by hand unsets it on its own.
  readonly property bool stealth: {
    if (devices.length === 0) return false
    for (var i = 0; i < devices.length; i++) if (!deviceIsOff(devices[i].name)) return false
    return true
  }

  function toggleDevicePower(index) {
    var dev = (index >= 0 && index < devices.length) ? devices[index] : null
    if (!dev || !service) return
    var next = {}
    for (var k in offMap) next[k] = offMap[k]
    if (next[dev.name] !== undefined) {
      var snap = next[dev.name]
      delete next[dev.name]
      service.restoreDevice(dev.index, snap)
    } else {
      next[dev.name] = service.blackout(dev.index)
    }
    persistSettings({ off: next })
  }

  function setStealth(on) {
    if (!service || devices.length === 0) return
    var next = {}
    for (var k in offMap) next[k] = offMap[k]
    for (var i = 0; i < devices.length; i++) {
      var dev = devices[i]
      if (on && next[dev.name] === undefined) {
        next[dev.name] = service.blackout(dev.index)
      } else if (!on && next[dev.name] !== undefined) {
        service.restoreDevice(dev.index, next[dev.name])
        delete next[dev.name]
      }
    }
    persistSettings({ off: next })
  }

  function toggleStealth() {
    setStealth(!stealth)
  }

  // A hand-picked color is the user taking control: theme sync stops fighting
  // it, and a device that was off is on again in the book-keeping.
  function noteManualColor(dev, hex) {
    var changes = ({})
    var dirty = false
    if (dev && offMap[String(dev.name)] !== undefined) {
      var next = {}
      for (var k in offMap) if (k !== String(dev.name)) next[k] = offMap[k]
      changes.off = next
      dirty = true
    }
    if (themeSync && Model.hexOf(hex) !== deviceAccent) {
      changes.themeSync = false
      dirty = true
    }
    if (dirty) persistSettings(changes)
  }

  // ---- Cursor state. One highlight on screen at a time, shared by the mouse
  //      and the keyboard (CursorSurface contract).
  property bool cursorActive: false
  property int selectedIndex: 0
  property int expandedDevice: -1
  property bool dropdownOpen: false

  // HSV for the expanded device's color controls. Kept here, not derived on
  // every render, so a drag does not fight the server's echo of the same
  // color coming back through a slightly different hue.
  property var editHsv: ({ h: 0, s: 0, v: 100 })
  readonly property string editHex: Model.hsvToHex(editHsv.h, editHsv.s, editHsv.v)

  readonly property var expandedDev: (expandedDevice >= 0 && expandedDevice < devices.length) ? devices[expandedDevice] : null
  readonly property var expandedMode: Model.activeMode(expandedDev)

  readonly property string heroStatus: {
    if (!service) return "Service not loaded"
    if (connected) {
      if (devices.length === 0) return "No devices found"
      return Model.plural(devices.length, "device")
    }
    if (service.serverStarting) return "Starting OpenRGB…"
    if (!service.bridgeReady) return "Starting bridge…"
    return "Not connected"
  }

  readonly property string tooltip: connected
    ? "OmaRGB · " + Model.plural(devices.length, "device")
    : "OmaRGB · " + (service && service.serverStarting ? "starting server" : "not connected")

  // ---- Settings plumbing -------------------------------------------------

  // The shell injects settings into bar widgets only; the service gets them
  // from here so theme sync and the host/port work without the popup open.
  function pushSettings() {
    if (service && "settings" in service) service.settings = root.settings
  }

  onServiceChanged: pushSettings()
  onSettingsChanged: pushSettings()
  Component.onCompleted: pushSettings()

  // Settings keys earlier versions of this plugin wrote; silently dropped
  // whenever the entry is rewritten so a long-lived shell.json stays clean.
  readonly property var obsoleteKeys: ["effect", "effectSpeed", "effectFps", "directSwap", "channelOrders"]

  // Applied locally first so the control moves on the click; the shell.json
  // write comes back through the bar as the same value.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id" && obsoleteKeys.indexOf(existing) === -1) entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setThemeSync(on) {
    persistSettings({ themeSync: on === true })
  }

  function toggleThemeSync() {
    setThemeSync(!themeSync)
  }

  // ---- Actions -------------------------------------------------------------

  // The `omarchy plugin add` installer never runs package managers, so getting
  // OpenRGB onto the system is a separate step. Rather than ask the user to
  // drop to a shell, run the plugin's own setup script in an Omarchy floating
  // terminal — the same path SystemUpdate and the setup menu use. sudo is
  // prompted for there, in the user's terminal; the plugin holds no rights.
  readonly property string setupPath: Qt.resolvedUrl("setup").toString().replace(/^file:\/\//, "")

  function installOpenRgb() {
    if (bar && typeof bar.run === "function")
      bar.run("omarchy-launch-floating-terminal-with-presentation \"bash '" + setupPath + "'\"")
  }

  function applyAccent() {
    setAll(deviceAccent)
  }

  function refresh() {
    if (service) service.refresh()
  }

  function setAll(hex) {
    if (!service) return
    service.setAll(hex)
    var changes = ({})
    var dirty = false
    // "All devices" means all: painting everything relights what was off.
    if (Object.keys(offMap).length > 0) {
      changes.off = ({})
      dirty = true
    }
    if (themeSync && Model.hexOf(hex) !== deviceAccent) {
      changes.themeSync = false
      dirty = true
    }
    if (dirty) persistSettings(changes)
  }

  function toggleExpanded(index) {
    expandedDevice = expandedDevice === index ? -1 : index
  }

  function setDeviceMode(index, modeIndex) {
    var dev = (index >= 0 && index < devices.length) ? devices[index] : null
    if (!dev || !dev.modes || !service) return
    if (!(modeIndex >= 0 && modeIndex < dev.modes.length)) return
    service.setMode(dev.index, modeIndex)
    var changes = ({})
    var dirty = false
    if (offMap[String(dev.name)] !== undefined) {
      var next = {}
      for (var k in offMap) if (k !== String(dev.name)) next[k] = offMap[k]
      changes.off = next
      dirty = true
    }
    // Choosing a hardware effect hands the color to the controller; the theme
    // has nothing to govern there any more.
    if (themeSync && !dev.modes[modeIndex].acceptsColor) {
      changes.themeSync = false
      dirty = true
    }
    if (dirty) persistSettings(changes)
  }

  function stepMode(index, delta) {
    var dev = (index >= 0 && index < devices.length) ? devices[index] : null
    if (!dev || !dev.modes || dev.modes.length === 0) return
    setDeviceMode(index, (dev.activeMode + delta + dev.modes.length) % dev.modes.length)
  }

  function saveSelected() {
    var dev = (selectedIndex >= 0 && selectedIndex < devices.length) ? devices[selectedIndex] : null
    var mode = Model.activeMode(dev)
    if (dev && mode && mode.canSave && service) service.saveDevice(dev.index)
  }

  function setEditHsv(h, s, v) {
    editHsv = { h: h, s: s, v: v }
    if (expandedDev && service) service.previewColor(expandedDev.index, editHex)
  }

  function commitEditColor() {
    if (!expandedDev || !service) return
    service.setColor(expandedDev.index, editHex)
    noteManualColor(expandedDev, editHex)
  }

  function pickDeviceColor(hex) {
    editHsv = Model.rgbToHsv(hex)
    if (expandedDev && service) {
      service.setColor(expandedDev.index, Model.hexOf(hex))
      noteManualColor(expandedDev, hex)
    }
  }

  // Re-seed the sliders from the server only when it disagrees with what the
  // sliders already encode, so an echo of our own write cannot nudge them.
  function syncEditColor() {
    if (!expandedDev) return
    var current = Model.hexOf(expandedDev.color)
    if (current === "" || current === editHex) return
    editHsv = Model.rgbToHsv(current)
  }

  onExpandedDevChanged: syncEditColor()

  // ---- Keyboard cursor -----------------------------------------------------

  function moveCursor(delta) {
    if (devices.length === 0) return
    selectedIndex = Math.max(0, Math.min(devices.length - 1, selectedIndex + delta))
  }

  function activateCursor() {
    if (devices.length === 0) return
    toggleExpanded(Math.max(0, Math.min(devices.length - 1, selectedIndex)))
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      if (selectedIndex >= devices.length) selectedIndex = 0
      syncEditColor()
    } else {
      dropdownOpen = false
    }
  }

  onDevicesChanged: {
    if (expandedDevice >= devices.length) expandedDevice = -1
    if (selectedIndex >= devices.length) selectedIndex = Math.max(0, devices.length - 1)
    // A change made elsewhere (the OpenRGB app, another client) must reach the
    // open row's sliders and dot too, not only its subtitle.
    syncEditColor()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "omargb"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function setAll(color: string): void { root.setAll(color) }
    function applyAccent(): void { root.applyAccent() }
    function themeSync(enabled: string): void { root.setThemeSync(enabled === "true") }
    function stealth(enabled: string): void { root.setStealth(enabled === "true") }
    function toggleStealth(): void { root.toggleStealth() }
  }

  // ---- Bar button: a dot in the lighting color --------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltip
    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: Math.round(parent.width * 0.78)
          height: width
          radius: width / 2
          color: root.connected && root.summaryColor !== "" ? root.summaryColor : "transparent"
          border.width: Math.max(1, Style.space(1.5))
          border.color: root.connected
            ? Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.85)
            : Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.4)

          Behavior on color { ColorAnimation { duration: 160 } }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.applyAccent()
      else if (b === Qt.MiddleButton) root.toggleThemeSync()
      else root.toggle()
    }
  }

  // ---- Popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.dropdownOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.stepMode(root.selectedIndex, dx)
      }
      onActivateRequested: { root.cursorActive = true; root.activateCursor() }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.toggleThemeSync()
        else if (t === "a" || t === "A") root.applyAccent()
        else if (t === "s" || t === "S") root.saveSelected()
        else if (t === "o" || t === "O") root.toggleStealth()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

          // ---------- Hero. The trailing switch is the master light
          // switch, in the same seat audio's mute-all occupies: checked means
          // something is lit, so switching it off reads as stealth.
          PanelHero {
            title: "OmaRGB"
            meta: root.heroStatus
            foreground: root.fg
            fontFamily: root.fontFamily
            iconComponent: Component {
              Item {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display

                Rectangle {
                  anchors.centerIn: parent
                  width: Math.round(parent.width * 0.86)
                  height: width
                  radius: width / 2
                  color: root.connected && root.summaryColor !== "" ? root.summaryColor : "transparent"
                  border.width: Math.max(1, Style.space(2))
                  border.color: root.connected ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.85) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.4)

                  Behavior on color { ColorAnimation { duration: 160 } }
                }
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: lightsSwitch
                visible: root.connected && root.devices.length > 0
                checked: !root.stealth
                foreground: root.fg
                onToggled: root.toggleStealth()

                PanelToolTip {
                  visible: lightsSwitch.containsMouse
                  text: root.stealth ? "Lights back on" : "Stealth mode — every light off, remembered per device"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---------- Not connected ----------
          Column {
            visible: !root.connected
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: {
                if (!root.service) return "The OpenRGB service did not load. Check `qs log` for the plugin's errors."
                if (root.service.serverStarting) return "Waiting for the OpenRGB server to come up…"
                if (!root.service.bridgeReady) return "Starting the OpenRGB bridge…"
                var err = root.service.lastError
                if (err.indexOf("no OpenRGB server") === 0)
                  return "Nothing answers on " + root.service.host + ":" + root.service.port + ". OpenRGB has to run as an SDK server for the bar to talk to it."
                return err !== "" ? err : "Connecting…"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              visible: !!root.service && !root.service.hasOpenRgb
              width: parent.width
              wrapMode: Text.WordWrap
              text: "OpenRGB isn't installed yet — it's the engine this widget drives. Install it to control your lighting from here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              visible: !!root.service && !root.service.hasOpenRgb
              text: "Install OpenRGB"
              iconText: "󰇚"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              tooltipText: "Opens a terminal and runs the plugin's setup script (sudo pacman -S openrgb)"
              onClicked: root.installOpenRgb()
            }

            Button {
              visible: !!root.service && root.service.hasOpenRgb && !root.service.serverStarting
              text: "Start OpenRGB server"
              iconText: "󰐥"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.service.startServer()
            }
          }

          // ---------- Connected ----------
          Column {
            visible: root.connected
            width: parent.width
            spacing: Style.space(14)

            Text {
              visible: root.actionError !== ""
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.actionError
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: "ALL DEVICES"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: root.swatches
                  Swatch {
                    required property var modelData
                    hex: modelData.hex
                    name: modelData.name
                    accent: modelData.accent === true
                    selected: false
                    onClicked: root.setAll(modelData.hex)
                  }
                }
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(themeSyncLabel.implicitHeight, themeSyncSwitch.implicitHeight)

                MouseArea {
                  id: themeSyncMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleThemeSync()
                }

                Text {
                  id: themeSyncLabel
                  anchors.left: parent.left
                  anchors.right: themeSyncSwitch.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Follow the theme accent"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                ToggleSwitch {
                  id: themeSyncSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  trackHeight: Math.round(Style.font.body * 1.2)
                  cursorPad: Style.space(3)
                  checked: root.themeSync
                  foreground: root.fg
                  onToggled: root.toggleThemeSync()
                }

                PanelToolTip {
                  visible: themeSyncMouse.containsMouse
                  text: "Repaint every device with the accent whenever the theme changes"
                  fontFamily: root.fontFamily
                }
              }
            }

            PanelSeparator { foreground: root.fg }

            Column {
              id: deviceList
              width: parent.width
              spacing: Style.space(4)

              Item {
                width: parent.width
                implicitHeight: Math.max(devicesHeader.implicitHeight, refreshButton.implicitHeight)

                PanelSectionHeader {
                  id: devicesHeader
                  anchors.left: parent.left
                  anchors.right: refreshButton.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "DEVICES"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                }

                PanelActionButton {
                  id: refreshButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰑐"
                  tooltipText: "Refresh devices"
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  enabled: root.connected
                  onClicked: root.refresh()
                }
              }

              Text {
                visible: root.devices.length === 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: "OpenRGB found no devices. Check `openrgb --list-devices` after installing its udev rules; some motherboards need i2c-dev loaded."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                topPadding: Style.space(4)
              }

              // Keyed by count, not by the array: the bridge republishes the
              // list after every change and on its change poll, and a fresh
              // model array would destroy every delegate — including the
              // slider currently under the pointer. With a stable count the
              // delegates persist and only their `dev` binding updates.
              Repeater {
                model: root.devices.length
                DeviceRow {
                  required property int index
                  width: deviceList.width
                  dev: root.devices[index] || null
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- Components -----------------------------------------------------------

  component Swatch: Item {
    id: swatch
    property string hex: "#000000"
    property string name: ""
    property bool accent: false
    property bool selected: false
    signal clicked()

    width: Style.space(26)
    height: width

    Rectangle {
      anchors.centerIn: parent
      width: parent.width - Style.space(4)
      height: width
      radius: width / 2
      color: swatch.hex
      border.width: swatch.selected || swatchMouse.containsMouse ? Math.max(1, Style.space(2)) : 1
      border.color: swatch.selected || swatchMouse.containsMouse
        ? root.fg
        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, Model.isBlack(swatch.hex) ? 0.6 : 0.35)
      scale: swatchMouse.containsMouse ? 1.12 : 1.0

      Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

      // The accent swatch carries a mark so it stands out from the presets.
      // A drawn circle, not a font glyph: glyph ink sits off-centre in its em
      // box, and inside a small ring the eye catches every pixel of that.
      Rectangle {
        visible: swatch.accent
        width: Math.max(4, Math.round(parent.width * 0.32))
        height: width
        // Integer position, not centerIn: an odd margin split in half lands
        // the mark on a fractional pixel, which reads as off-centre at this
        // size.
        x: Math.round((parent.width - width) / 2)
        y: Math.round((parent.height - height) / 2)
        radius: width / 2
        color: Model.isLight(swatch.hex) ? "#000000" : "#ffffff"
        opacity: 0.8
      }
    }

    MouseArea {
      id: swatchMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: swatch.clicked()
    }

    PanelToolTip {
      visible: swatchMouse.containsMouse && swatch.name !== ""
      text: swatch.name
      fontFamily: root.fontFamily
    }
  }

  component SliderRow: Item {
    id: sliderRow
    property string label: ""
    property string suffix: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property real step: 1
    signal moved(real value)
    signal released(real value)

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(slider.implicitHeight, sliderLabel.implicitHeight)

    Text {
      id: sliderLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(76)
      text: sliderRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    PanelSlider {
      id: slider
      anchors.left: sliderLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.right: sliderValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      bar: root.bar
      integer: true
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.step
      value: sliderRow.value
      onMoved: function(v) { sliderRow.moved(v) }
      onReleased: function(v) { sliderRow.released(v) }
    }

    Text {
      id: sliderValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(40)
      horizontalAlignment: Text.AlignRight
      text: String(Math.round(slider.liveValue)) + sliderRow.suffix
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component DeviceRow: CursorSurface {
    id: row
    property var dev: null
    required property int rowIndex

    readonly property var mode: Model.activeMode(dev)
    readonly property string activeModeValue: dev ? String(dev.activeMode) : "0"
    readonly property bool expanded: root.expandedDevice === rowIndex

    // The stock Dropdown assigns its own `value` on a pick, which severs any
    // binding feeding it. Push the server's mode in by hand instead, so a
    // mode changed elsewhere shows up here rather than the last pick.
    onActiveModeValueChanged: modeDropdown.value = activeModeValue
    readonly property bool off: root.deviceIsOff(dev ? dev.name : "")
    readonly property string colorHex: {
      if (off) return ""
      if (expanded && mode && mode.acceptsColor) return root.editHex
      return Model.hexOf(dev ? dev.color : "")
    }
    readonly property bool rowSelected: root.cursorActive && root.selectedIndex === rowIndex

    hasCursor: rowSelected
    current: expanded
    foreground: root.fg
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowColumn.implicitHeight + Style.spacing.rowPaddingX

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX / 2
      anchors.rightMargin: Style.spacing.rowPaddingX / 2
      spacing: Style.space(10)

      // ---- Header: icon · name/subtitle · color dot · chevron
      Item {
        width: parent.width
        implicitHeight: Math.max(typeIcon.implicitHeight, nameColumn.implicitHeight, powerButton.implicitHeight, Style.space(30))

        MouseArea {
          id: headerMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.selectedIndex = row.rowIndex }
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) root.stepMode(row.rowIndex, 1)
            else root.toggleExpanded(row.rowIndex)
          }
        }

        Text {
          id: typeIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(24)
          text: Model.typeIcon(row.dev ? row.dev.typeName : "")
          color: root.fg
          opacity: row.off ? 0.55 : 1
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          horizontalAlignment: Text.AlignHCenter
        }

        Column {
          id: nameColumn
          anchors.left: typeIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: colorDot.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)
          opacity: row.off ? 0.55 : 1

          Text {
            width: parent.width
            text: Model.displayName(row.dev)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: Model.deviceSubtitle(row.dev)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Rectangle {
          id: colorDot
          anchors.right: powerButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(14)
          height: width
          radius: width / 2
          color: row.colorHex !== "" ? row.colorHex : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, row.colorHex !== "" ? 0.5 : 0.3)

          Behavior on color { ColorAnimation { duration: 120 } }
        }

        PanelActionButton {
          id: powerButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰐥"
          tooltipText: row.off ? "Turn its lighting back on" : "Turn its lighting off"
          foreground: root.fg
          fontFamily: root.fontFamily
          opacity: row.off ? 1 : 0.55
          onClicked: root.toggleDevicePower(row.rowIndex)
        }
      }

      // ---- Controls, one device at a time
      Column {
        visible: row.expanded
        width: parent.width
        spacing: Style.space(12)
        leftPadding: Style.space(34)

        // Mode
        Item {
          width: parent.width - parent.leftPadding
          implicitHeight: modeDropdown.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(76)
            text: "Mode"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Dropdown {
            id: modeDropdown
            anchors.right: parent.right
            anchors.left: parent.left
            anchors.leftMargin: Style.space(84)
            anchors.verticalCenter: parent.verticalCenter
            showLabel: false
            fontFamily: root.fontFamily
            options: Model.modeOptions(row.dev)
            value: row.activeModeValue
            onPopupOpenChanged: root.dropdownOpen = popupOpen
            onChanged: function(v) { root.setDeviceMode(row.rowIndex, Number(v)) }
          }
        }

        // Color
        Column {
          visible: !!row.mode && row.mode.acceptsColor
          width: parent.width - parent.leftPadding
          spacing: Style.space(8)

          Flow {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.swatches
              Swatch {
                required property var modelData
                hex: modelData.hex
                name: modelData.name
                accent: modelData.accent === true
                selected: row.colorHex === modelData.hex
                onClicked: root.pickDeviceColor(modelData.hex)
              }
            }
          }

          SliderRow {
            label: "Hue"
            minimum: 0
            maximum: 359
            suffix: "°"
            value: root.editHsv.h
            onMoved: function(v) { root.setEditHsv(v, root.editHsv.s, root.editHsv.v) }
            onReleased: root.commitEditColor()
          }

          SliderRow {
            label: "Saturation"
            minimum: 0
            maximum: 100
            suffix: "%"
            value: root.editHsv.s
            onMoved: function(v) { root.setEditHsv(root.editHsv.h, v, root.editHsv.v) }
            onReleased: root.commitEditColor()
          }

          SliderRow {
            label: "Value"
            minimum: 0
            maximum: 100
            suffix: "%"
            value: root.editHsv.v
            onMoved: function(v) { root.setEditHsv(root.editHsv.h, root.editHsv.s, v) }
            onReleased: root.commitEditColor()
          }
        }

        Text {
          visible: !!row.mode && !row.mode.acceptsColor
          width: parent.width - parent.leftPadding
          wrapMode: Text.WordWrap
          text: row.mode ? row.mode.name + " has no color of its own. Pick a swatch above to switch to a static color." : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Brightness / speed, when the mode has them
        // Controllers may publish inverted ranges (speedMin 255, speedMax 0);
        // mapping through a 0..100% fraction keeps the slider moving left-slow,
        // right-fast either way.
        SliderRow {
          visible: !!row.mode && row.mode.hasBrightness
          width: parent.width - parent.leftPadding
          label: "Brightness"
          minimum: 0
          maximum: 100
          suffix: "%"
          value: row.mode ? Model.rangeT(row.mode.brightness, row.mode.brightnessMin, row.mode.brightnessMax) * 100 : 0
          onReleased: function(v) {
            if (root.service && row.dev && row.mode)
              root.service.setBrightness(row.dev.index, Model.rangeValue(v / 100, row.mode.brightnessMin, row.mode.brightnessMax))
          }
        }

        SliderRow {
          visible: !!row.mode && row.mode.hasSpeed
          width: parent.width - parent.leftPadding
          label: "Speed"
          minimum: 0
          maximum: 100
          suffix: "%"
          value: row.mode ? Model.rangeT(row.mode.speed, row.mode.speedMin, row.mode.speedMax) * 100 : 0
          onReleased: function(v) {
            if (root.service && row.dev && row.mode)
              root.service.setSpeed(row.dev.index, Model.rangeValue(v / 100, row.mode.speedMin, row.mode.speedMax))
          }
        }

        Button {
          visible: !!row.mode && row.mode.canSave
          text: "Save to device"
          iconText: "󰆓"
          bordered: true
          foreground: root.fg
          fontFamily: root.fontFamily
          tooltipText: "Write the current mode to the device's own memory so it survives a reboot"
          onClicked: if (root.service && row.dev) root.service.saveDevice(row.dev.index)
        }
      }
    }
  }
}
