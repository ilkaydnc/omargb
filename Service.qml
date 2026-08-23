import QtQuick
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Headless owner of the OpenRGB connection. The shell creates exactly one of
// these per plugin, so the bridge process and the device list live here and
// every bar surface (one per monitor) reads them through
// `bar.shell.serviceFor(id)` instead of spawning its own.
//
// Talks to OpenRGB through bridge/openrgb_bridge.py: JSON commands in on
// stdin, JSON events out on stdout. The bridge re-reads device state after
// every change and polls for changes made by other clients, so `devices`
// mirrors what the server believes — not just what this panel last did.
Item {
  id: root

  // Injected by the shell when the service is created.
  property var shell: null
  property var manifest: null

  // The bar widget's inline shell.json entry, pushed by the widget — the shell
  // injects settings into bar widgets, not services.
  property var settings: ({})

  // ---- State read by the panel
  property bool connected: false
  property string host: "127.0.0.1"
  property int port: 6742
  property int protocol: 0
  property var devices: []
  property var profiles: []
  property string lastError: ""
  property string openrgbBinary: ""
  property bool bridgeReady: false
  property bool serverStarting: false
  property string actionError: ""

  readonly property int deviceCount: devices.length
  readonly property string summaryColor: Model.summaryColor(devices)
  readonly property string accentHex: Model.hexOf(Color.accent)
  readonly property bool hasOpenRgb: openrgbBinary !== ""

  readonly property string configuredHost: String(setting("host", "127.0.0.1") || "127.0.0.1")
  readonly property int configuredPort: Math.max(1, Math.min(65535, Number(setting("port", 6742)) || 6742))
  readonly property bool themeSync: setting("themeSync", false) === true
  readonly property bool autoStartServer: setting("autoStartServer", true) !== false
  readonly property bool vividAccent: setting("vividAccent", true) !== false

  // What actually goes to the hardware when "the accent" is applied.
  readonly property string deviceAccent: vividAccent ? Model.ledAccent(accentHex) : accentHex

  // Devices switched off from the panel, with what to put back when they come
  // on again: { "<device name>": { "mode": <index>, "color": "#rrggbb" } }.
  // The panel owns writing this (it persists settings); the service reads it
  // so theme sync leaves dark devices dark.
  readonly property var offRestore: setting("off", ({})) || ({})

  readonly property string bridgePath: Qt.resolvedUrl("bridge/openrgb_bridge.py").toString().replace(/^file:\/\//, "")

  // Once per shell session: spawning openrgb on every failed connect would
  // fight a server the user is starting by hand or through systemd.
  property bool autoStartAttempted: false
  property int consecutiveFailures: 0
  property int restartDelayMs: 2000

  // Slider drags produce a burst of colors per device; only the latest one
  // is worth a round trip, and none of them is worth a read-back.
  property var pendingColors: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function deviceAt(index) {
    return (index >= 0 && index < devices.length) ? devices[index] : null
  }

  // ---- Bridge I/O

  function send(obj) {
    if (!bridge.running) return false
    bridge.write(JSON.stringify(obj) + "\n")
    return true
  }

  function handleLine(line) {
    var trimmed = String(line || "").trim()
    if (trimmed === "") return
    var msg
    try {
      msg = JSON.parse(trimmed)
    } catch (e) {
      console.warn("openrgb: unreadable bridge line: " + trimmed)
      return
    }
    switch (msg.event) {
    case "hello":
      bridgeReady = true
      restartDelayMs = 2000
      openrgbBinary = msg.openrgbBinary ? String(msg.openrgbBinary) : ""
      break
    case "state":
      applyState(msg)
      break
    case "profiles":
      profiles = Array.isArray(msg.profiles) ? msg.profiles : []
      break
    case "result":
      if (msg.ok === false) {
        actionError = String(msg.error || "OpenRGB rejected the command")
        actionErrorTimer.restart()
      }
      break
    default:
      break
    }
  }

  function applyState(msg) {
    var wasConnected = connected
    host = String(msg.host || host)
    port = Number(msg.port) || port
    protocol = Number(msg.protocol) || 0
    if ("openrgbBinary" in msg) openrgbBinary = msg.openrgbBinary ? String(msg.openrgbBinary) : ""
    if (msg.connected) {
      connected = true
      consecutiveFailures = 0
      serverStarting = false
      lastError = ""
      devices = Array.isArray(msg.devices) ? msg.devices : []
      if (!wasConnected && themeSync) scheduleThemeApply()
    } else {
      connected = false
      devices = []
      lastError = String(msg.error || "")
      consecutiveFailures += 1
      maybeAutoStart()
    }
  }

  // ---- Server lifecycle

  function maybeAutoStart() {
    if (!autoStartServer || autoStartAttempted || !hasOpenRgb) return
    if (lastError.indexOf("no OpenRGB server") === -1) return
    // Two refusals in a row: a server that is merely still booting gets a
    // moment before we spawn a second one on top of it.
    if (consecutiveFailures < 2) return
    startServer()
  }

  function startServer() {
    if (!hasOpenRgb) return
    autoStartAttempted = true
    serverStarting = true
    serverStartTimer.restart()
    send({ op: "start_server" })
  }

  function refresh() {
    send({ op: "refresh" })
  }

  // ---- Device commands

  // Streamed while a slider is held: coalesced here, quiet at the bridge, so
  // the device follows the drag without the device list being republished
  // dozens of times a second (which would tear down the very slider being
  // dragged). setColor() is the definitive write that ends such a stream.
  function previewColor(index, hex) {
    var color = Model.hexOf(hex)
    if (color === "" || !deviceAt(index)) return
    var next = {}
    for (var k in pendingColors) next[k] = pendingColors[k]
    next[String(index)] = color
    pendingColors = next
    if (!colorFlushTimer.running) colorFlushTimer.start()
  }

  function flushColors() {
    var batch = pendingColors
    pendingColors = ({})
    for (var key in batch) send({ op: "set_color", device: Number(key), color: batch[key], quiet: true })
  }

  function setColor(index, hex) {
    var color = Model.hexOf(hex)
    if (color === "" || !deviceAt(index)) return
    // Anything still queued for this device is older than the color in hand;
    // sending it after the loud write would put a stale color on the device.
    if (pendingColors[String(index)] !== undefined) {
      var next = {}
      for (var k in pendingColors) if (k !== String(index)) next[k] = pendingColors[k]
      pendingColors = next
    }
    send({ op: "set_color", device: index, color: color })
  }

  function setZoneColor(index, zone, hex) {
    var color = Model.hexOf(hex)
    if (color === "" || !deviceAt(index)) return
    send({ op: "set_color", device: index, zone: zone, color: color })
  }

  function setMode(index, modeIndex) {
    if (!deviceAt(index)) return
    send({ op: "set_mode", device: index, mode: modeIndex })
  }

  function setBrightness(index, value) {
    if (!deviceAt(index)) return
    send({ op: "set_brightness", device: index, value: Math.round(value) })
  }

  function setSpeed(index, value) {
    if (!deviceAt(index)) return
    send({ op: "set_speed", device: index, value: Math.round(value) })
  }

  function saveDevice(index) {
    if (!deviceAt(index)) return
    send({ op: "save", device: index })
  }

  function setAll(hex) {
    var color = Model.hexOf(hex)
    if (color === "") return
    send({ op: "set_all", color: color })
  }

  function loadProfile(name) {
    send({ op: "load_profile", name: String(name) })
  }

  function saveProfile(name) {
    send({ op: "save_profile", name: String(name) })
  }

  // ---- Power

  // Turn one device dark and hand back what would bring it back. The panel
  // persists the snapshot in its settings; the service holds no copy, so a
  // shell restart cannot strand a device with no way back.
  //
  // Dark means "paint every LED black", not the controller's own Off mode:
  // Off can stop driving the ARGB data line altogether, and fans or strips
  // that carry a fallback controller of their own treat a silent line as
  // "no host" and revert to their built-in rainbow. Black keeps the stream
  // alive with every LED dark. Off stays as the last resort for a device
  // with no color-capable mode at all.
  function blackout(index) {
    var dev = deviceAt(index)
    if (!dev) return ({})
    var snap = { mode: dev.activeMode }
    var color = Model.hexOf(dev.color)
    if (color !== "") snap.color = color
    if (Model.hasColorMode(dev)) send({ op: "set_color", device: index, color: "#000000" })
    else if (Model.offModeIndex(dev) >= 0) setMode(index, Model.offModeIndex(dev))
    return snap
  }

  function restoreDevice(index, snap) {
    var dev = deviceAt(index)
    if (!dev) return
    var mode = snap && typeof snap.mode === "number" ? snap.mode : -1
    var color = snap ? Model.hexOf(snap.color) : ""
    if (mode >= 0 && dev.modes && mode < dev.modes.length) {
      if (color !== "") send({ op: "set_mode", device: index, mode: mode, color: color })
      else send({ op: "set_mode", device: index, mode: mode })
    } else if (color !== "") {
      send({ op: "set_color", device: index, color: color })
    } else {
      // No snapshot survived; the accent is the least arbitrary color to wake to.
      send({ op: "set_color", device: index, color: deviceAccent !== "" ? deviceAccent : "#ffffff" })
    }
  }

  // ---- Theme sync

  function applyTheme() {
    if (!themeSync || !connected || deviceAccent === "") return
    var off = offRestore
    for (var i = 0; i < devices.length; i++) {
      if (off[devices[i].name] !== undefined) continue
      send({ op: "set_color", device: devices[i].index, color: deviceAccent, quiet: true })
    }
    // One loud read-back for the batch, so the panel and the bar dot settle.
    refresh()
  }

  function scheduleThemeApply() {
    if (!themeSync) return
    themeApplyTimer.restart()
  }

  onDeviceAccentChanged: scheduleThemeApply()
  onThemeSyncChanged: if (themeSync) scheduleThemeApply()

  onConfiguredHostChanged: send({ op: "connect", host: configuredHost, port: configuredPort })
  onConfiguredPortChanged: send({ op: "connect", host: configuredHost, port: configuredPort })

  Timer {
    // A theme switch moves several colors in quick succession; one write
    // after the dust settles is enough.
    id: themeApplyTimer
    interval: 350
    repeat: false
    onTriggered: root.applyTheme()
  }

  Timer {
    id: colorFlushTimer
    interval: 40
    repeat: false
    onTriggered: root.flushColors()
  }

  Timer {
    id: actionErrorTimer
    interval: 4000
    repeat: false
    onTriggered: root.actionError = ""
  }

  Timer {
    // Clears the "starting…" state if the server never shows up.
    id: serverStartTimer
    interval: 15000
    repeat: false
    onTriggered: root.serverStarting = false
  }

  Timer {
    id: restartTimer
    interval: root.restartDelayMs
    repeat: false
    onTriggered: bridge.running = true
  }

  Process {
    id: bridge
    command: ["python3", root.bridgePath, "--host", root.configuredHost, "--port", String(root.configuredPort)]
    stdinEnabled: true

    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root.handleLine(data) }
    }

    stderr: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { if (String(data).trim() !== "") console.warn(String(data)) }
    }

    onExited: function(exitCode, exitStatus) {
      root.bridgeReady = false
      root.connected = false
      root.devices = []
      if (root.lastError === "") root.lastError = "the OpenRGB bridge exited (" + exitCode + ")"
      root.restartDelayMs = Math.min(30000, root.restartDelayMs * 2)
      restartTimer.restart()
    }
  }

  Component.onCompleted: bridge.running = true
  Component.onDestruction: { if (bridge.running) root.send({ op: "quit" }) }
}
