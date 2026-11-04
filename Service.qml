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
  readonly property int globalBrightness: Model.brightnessPercent(setting("globalBrightness", 100))
  readonly property var brightnessColors: setting("brightnessColors", ({})) || ({})

  // What actually goes to the hardware when "the accent" is applied.
  readonly property string deviceAccent: vividAccent ? Model.ledAccent(accentHex) : accentHex

  // Devices switched off from the panel, with what to put back when they come
  // on again: { "<Model.deviceKey>": { "mode": <index>, "color": "#rrggbb" } }.
  // The panel owns writing this (it persists settings); the service reads it
  // so theme sync leaves dark devices dark.
  readonly property var offRestore: setting("off", ({})) || ({})

  // Mode, color, brightness and speed last chosen for each device. Direct and
  // most other modes cannot be saved onto the hardware, so this is what comes
  // back when OpenRGB starts with its own defaults. The panel writes it.
  readonly property var litRestore: setting("lit", ({})) || ({})

  // OpenRGB accepts SDK clients while device detection is still running, and
  // a controller often resets to its default a moment after it first appears.
  // Restore waits until the device list stops changing, then keeps writing
  // until a read-back matches or the deadline passes.
  property bool restoreSettled: false
  property bool restoreHold: false
  property bool restoreInFlight: false
  property bool restoreDimmed: false
  property double restoreDeadlineMs: 0
  property string deviceSignature: ""

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
      restoreInFlight = false
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
      restoreInFlight = false
      devices = Array.isArray(msg.devices) ? msg.devices : []
      var signature = deviceSignatureOf(devices)
      if (themeSync) {
        // The accent is painted by scheduleThemeApply. Remembering `lit` is
        // the panel's job; applying it here would fight the theme.
        deviceSignature = signature
        restoreHold = false
        restoreSettled = true
        restoreTimer.stop()
        if (!wasConnected) {
          // Re-assert the dimmer before theme paint so a reconnect cannot
          // snapshot already-scaled hardware as the new full-bright color.
          // At 100% there is nothing to re-assert.
          if (globalBrightness < 100) applyGlobalBrightness(globalBrightness, true, [])
          scheduleThemeApply()
        }
      } else if (!wasConnected || signature !== deviceSignature) {
        armRestore()
      }
    } else {
      connected = false
      restoreInFlight = false
      restoreSettled = false
      restoreHold = false
      restoreDimmed = false
      restoreTimer.stop()
      deviceSignature = ""
      devices = []
      lastError = String(msg.error || "")
      consecutiveFailures += 1
      maybeAutoStart()
    }
  }

  function deviceSignatureOf(devs) {
    var parts = []
    for (var i = 0; i < devs.length; i++)
      parts.push(Model.deviceKey(devs[i]) + "#" + devs[i].index)
    return parts.join("|")
  }

  // Push the deadline out and stay quiet until the list has held still.
  // Detection adds devices for several seconds after the server starts
  // answering; writing into that window is what gets wiped.
  function armRestore() {
    deviceSignature = deviceSignatureOf(devices)
    restoreHold = true
    restoreSettled = false
    restoreInFlight = false
    restoreDimmed = false
    restoreDeadlineMs = Date.now() + 20000
    restoreTimer.restart()
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

  // indices: device indexes to touch; omit to skip stealth-off devices.
  // Passing colors pins the logical (full-bright) RGB the dimmer scales from.
  function applyGlobalBrightness(percent, quiet, indices, colors) {
    var value = Model.brightnessPercent(percent === undefined || percent === null ? globalBrightness : percent)
    var payload = { op: "set_all_brightness", value: value, quiet: quiet === true }
    if (indices === undefined || indices === null) {
      var off = offRestore
      var live = []
      for (var i = 0; i < devices.length; i++) {
        if (Model.offKey(off, devices[i]) !== "") continue
        live.push(devices[i].index)
      }
      indices = live
    }
    payload.devices = indices
    if (colors) payload.colors = colors
    send(payload)
  }

  function brightnessColorMap() {
    return Model.brightnessColorMap(devices, brightnessColors)
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
    if (Model.hasColorMode(dev)) send({ op: "set_color", device: index, color: "#000000", store: false })
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
      if (Model.offKey(off, devices[i]) !== "") continue
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
  // Turning theme sync off must not replay `lit`. The panel has just written
  // the accent into it; a boot-style restore here would paint the colors from
  // before sync, which is the bug the switch is not allowed to have.
  onThemeSyncChanged: {
    if (!themeSync) return
    scheduleThemeApply()
    restoreHold = false
    restoreSettled = true
    restoreTimer.stop()
  }
  onSettingsChanged: if (!themeSync && !restoreHold) applyRemembered()

  // Put the stored mode and color back. A device counts as done only when a
  // later read-back matches, so a controller that resets after the first
  // write gets another try. Devices the panel switched off are left alone.
  // Matching early does not end the window: a reset can still land inside it.
  function applyRemembered() {
    if (!connected || restoreHold) return
    if (themeSync) {
      restoreSettled = true
      restoreTimer.stop()
      return
    }
    if (restoreInFlight) {
      if (Date.now() < restoreDeadlineMs + 5000) return
      restoreInFlight = false
    }
    // The bridge starts at full brightness. Set the dimmer from the remembered
    // colors before the per-device writes, so those writes are scaled and the
    // dimmer does not first flash the unrelated brightnessColors map.
    if (!restoreDimmed && globalBrightness < 100) {
      restoreDimmed = true
      applyGlobalBrightness(globalBrightness, true, null, rememberedColorMap())
    }
    var lit = Model.plain(litRestore)
    var off = Model.plain(offRestore)
    var expired = restoreDeadlineMs > 0 && Date.now() >= restoreDeadlineMs
    var missed = []
    var sent = false
    for (var i = 0; i < devices.length; i++) {
      var dev = devices[i]
      var key = Model.deviceKey(dev)
      if (key === "") continue
      if (Model.offKey(off, dev) !== "") continue
      var snap = Model.lookupSnap(lit, dev)
      if (!snap) continue
      if (Model.snapMatches(dev, snap)) continue
      if (expired) {
        missed.push(String(dev.name || key))
        continue
      }
      if (applyLitSnap(dev, snap)) sent = true
    }
    if (sent) restoreInFlight = true
    if (expired) {
      if (missed.length) console.warn("openrgb: did not restore " + missed.join(", "))
      restoreSettled = true
      restoreTimer.stop()
    }
  }

  // Logical colors for the dimmer. Per-device brightness is omitted while the
  // slider is below 100%, because the slider owns that field.
  function rememberedColorMap() {
    var map = ({})
    var lit = Model.plain(litRestore)
    var off = Model.plain(offRestore)
    for (var i = 0; i < devices.length; i++) {
      var dev = devices[i]
      if (Model.offKey(off, dev) !== "") continue
      var snap = Model.lookupSnap(lit, dev)
      var hex = snap ? Model.hexOf(snap.color) : ""
      if (hex !== "") map[String(dev.index)] = hex
    }
    return map
  }

  function applyLitSnap(dev, snap) {
    var sent = false
    var modeName = snap.mode ? String(snap.mode) : ""
    var color = Model.hexOf(snap.color)
    var mode = Model.modeByName(dev, modeName)
    var current = Model.activeMode(dev)
    var modeOk = modeName === "" || (current && current.name === modeName)
    var colorOk = color === "" || Model.hexOf(dev.color) === color
    if (!modeOk || !colorOk) {
      if (mode) {
        if (color !== "" && mode.acceptsColor)
          send({ op: "set_mode", device: dev.index, mode: mode.index, color: color })
        else
          send({ op: "set_mode", device: dev.index, mode: mode.index })
        sent = true
      } else if (color !== "") {
        send({ op: "set_color", device: dev.index, color: color })
        sent = true
      }
    }
    var target = mode || current
    if (globalBrightness >= 100 && target && target.hasBrightness && typeof snap.brightness === "number"
        && Number(target.brightness) !== Number(snap.brightness)) {
      send({ op: "set_brightness", device: dev.index, value: snap.brightness })
      sent = true
    }
    if (target && target.hasSpeed && typeof snap.speed === "number"
        && Number(target.speed) !== Number(snap.speed)) {
      send({ op: "set_speed", device: dev.index, value: snap.speed })
      sent = true
    }
    return sent
  }

  onConfiguredHostChanged: send({ op: "connect", host: configuredHost, port: configuredPort })
  onConfiguredPortChanged: send({ op: "connect", host: configuredHost, port: configuredPort })

  Timer {
    // Fires once the device list has been quiet, then again until the
    // deadline. restart() from armRestore() is what waits out detection.
    id: restoreTimer
    interval: 2000
    repeat: true
    onTriggered: {
      root.restoreHold = false
      root.applyRemembered()
    }
  }

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
      root.restoreInFlight = false
      root.restoreSettled = false
      root.restoreHold = false
      root.restoreDimmed = false
      root.deviceSignature = ""
      restoreTimer.stop()
      root.devices = []
      if (root.lastError === "") root.lastError = "the OpenRGB bridge exited (" + exitCode + ")"
      root.restartDelayMs = Math.min(30000, root.restartDelayMs * 2)
      restartTimer.restart()
    }
  }

  Component.onCompleted: bridge.running = true
  Component.onDestruction: { if (bridge.running) root.send({ op: "quit" }) }
}
