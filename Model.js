.pragma library

// Pure helpers for the OpenRGB plugin: color math, labels and icons. No QML
// objects in here so both Service.qml and Panel.qml can share it.

var TYPE_ICONS = {
  motherboard: "󰆠",
  dram: "󰍛",
  gpu: "󰢮",
  cooler: "󰈐",
  ledstrip: "󰟖",
  keyboard: "󰌌",
  mouse: "󰍽",
  mousemat: "󰍿",
  headset: "󰋎",
  headset_stand: "󰋋",
  gamepad: "󰊖",
  light: "󰌵",
  speaker: "󰓃",
  virtual: "󰝥",
  storage: "󰋊",
  case: "󰄄",
  microphone: "󰍬",
  accessory: "󰊙",
  keypad: "󰌌",
  laptop: "󰌢",
  monitor: "󰍹"
}

var TYPE_LABELS = {
  motherboard: "Motherboard",
  dram: "Memory",
  gpu: "Graphics card",
  cooler: "Cooler",
  ledstrip: "LED strip",
  keyboard: "Keyboard",
  mouse: "Mouse",
  mousemat: "Mouse mat",
  headset: "Headset",
  headset_stand: "Headset stand",
  gamepad: "Gamepad",
  light: "Light",
  speaker: "Speaker",
  virtual: "Virtual",
  storage: "Storage",
  case: "Case",
  microphone: "Microphone",
  accessory: "Accessory",
  keypad: "Keypad",
  laptop: "Laptop",
  monitor: "Monitor"
}

function typeIcon(typeName) {
  return TYPE_ICONS[typeName] || "󰛨"
}

function typeLabel(typeName) {
  return TYPE_LABELS[typeName] || "Device"
}

// ---- Colors ---------------------------------------------------------------

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v))
}

function hex2(n) {
  var s = clamp(Math.round(n), 0, 255).toString(16)
  return s.length < 2 ? "0" + s : s
}

// "#rrggbb" from a QML color, a "#rrggbb"/"#aarrggbb" string, or {r,g,b}.
function hexOf(color) {
  if (color === undefined || color === null) return ""
  if (typeof color === "string") {
    var s = color.trim()
    if (s.charAt(0) === "#") s = s.slice(1)
    if (s.length === 8) s = s.slice(2)
    if (s.length === 3) s = s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1) + s.charAt(2) + s.charAt(2)
    if (!/^[0-9a-fA-F]{6}$/.test(s)) return ""
    return "#" + s.toLowerCase()
  }
  if (typeof color.r === "number" && typeof color.g === "number" && typeof color.b === "number") {
    // QML colors carry 0..1 channels; plain objects carry 0..255.
    var scale = (color.r <= 1 && color.g <= 1 && color.b <= 1) ? 255 : 1
    return "#" + hex2(color.r * scale) + hex2(color.g * scale) + hex2(color.b * scale)
  }
  return hexOf(String(color))
}

function hexToRgb(hex) {
  var h = hexOf(hex)
  if (h === "") return { r: 0, g: 0, b: 0 }
  return {
    r: parseInt(h.slice(1, 3), 16),
    g: parseInt(h.slice(3, 5), 16),
    b: parseInt(h.slice(5, 7), 16)
  }
}

// h in degrees 0..360, s and v in 0..100.
function rgbToHsv(hex) {
  var c = hexToRgb(hex)
  var r = c.r / 255, g = c.g / 255, b = c.b / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var d = max - min
  var h = 0
  if (d > 0) {
    if (max === r) h = 60 * (((g - b) / d) % 6)
    else if (max === g) h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4)
    if (h < 0) h += 360
  }
  var s = max === 0 ? 0 : d / max
  return { h: Math.round(h) % 360, s: Math.round(s * 100), v: Math.round(max * 100) }
}

function hsvToHex(h, s, v) {
  h = ((h % 360) + 360) % 360
  s = clamp(s, 0, 100) / 100
  v = clamp(v, 0, 100) / 100
  var c = v * s
  var x = c * (1 - Math.abs((h / 60) % 2 - 1))
  var m = v - c
  var r = 0, g = 0, b = 0
  if (h < 60) { r = c; g = x }
  else if (h < 120) { r = x; g = c }
  else if (h < 180) { g = c; b = x }
  else if (h < 240) { g = x; b = c }
  else if (h < 300) { r = x; b = c }
  else { r = c; b = x }
  return "#" + hex2((r + m) * 255) + hex2((g + m) * 255) + hex2((b + m) * 255)
}

// Relative luminance, for deciding whether a check mark reads on a swatch.
// The accent as devices should wear it. A screen renders a muted accent
// through context; an LED just emits, and near-equal channels read as white.
// Keeping the hue but lifting saturation and value makes the theme's
// undertone visible on hardware. A truly neutral accent has no hue worth
// amplifying — white is its honest rendering, so it passes through.
function ledAccent(hex) {
  var h = hexOf(hex)
  if (h === "") return ""
  var hsv = rgbToHsv(h)
  if (hsv.s < 5) return h
  return hsvToHex(hsv.h, Math.max(hsv.s, 70), Math.max(hsv.v, 90))
}

function isLight(hex) {
  var c = hexToRgb(hex)
  return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255 > 0.6
}

function isBlack(hex) {
  return hexOf(hex) === "#000000"
}

// Some controllers publish inverted ranges (speedMin 255, speedMax 0 means
// "255 is slowest"). Mapping through a 0..1 fraction keeps sliders working in
// both directions: 0 is always the `lo` end (slow/dim), 1 always `hi`.
function rangeT(value, lo, hi) {
  if (lo === hi) return 1
  return clamp((value - lo) / (hi - lo), 0, 1)
}

function rangeValue(t, lo, hi) {
  return Math.round(lo + clamp(t, 0, 1) * (hi - lo))
}

// Software dimming for modes that have no hardware brightness: scale the
// logical color toward black. 1 is unchanged, 0 is off.
function scaleHex(hex, t) {
  var h = hexOf(hex)
  if (h === "") return ""
  t = clamp(t, 0, 1)
  if (t >= 1) return h
  if (t <= 0) return "#000000"
  var c = hexToRgb(h)
  return "#" + hex2(c.r * t) + hex2(c.g * t) + hex2(c.b * t)
}

function brightnessPercent(value) {
  var n = Number(value)
  if (!isFinite(n)) return 100
  return Math.round(clamp(n, 0, 100))
}

// { "<device index>": "#rrggbb" }: the full-bright color the dimmer scales
// each device from. A color picked here (stored, keyed by deviceKey) wins.
// Otherwise a single-color device sends its own color, and a multi-color one
// sends nothing so the bridge keeps its per-LED colors instead of flattening
// them to the most common one.
function brightnessColorMap(devices, stored) {
  var map = ({})
  for (var i = 0; i < (devices || []).length; i++) {
    var dev = devices[i]
    var key = deviceKey(dev)
    var hex = stored && stored[key] !== undefined ? hexOf(stored[key]) : ""
    if (hex === "" && dev.uniform !== false) hex = hexOf(dev.color)
    if (hex !== "") map[String(dev.index)] = hex
  }
  return map
}

var PRESETS = [
  { name: "White", hex: "#ffffff" },
  { name: "Red", hex: "#ff0000" },
  { name: "Orange", hex: "#ff6a00" },
  { name: "Yellow", hex: "#ffd000" },
  { name: "Green", hex: "#00ff40" },
  { name: "Cyan", hex: "#00e5ff" },
  { name: "Blue", hex: "#0040ff" },
  { name: "Purple", hex: "#8a2bff" },
  { name: "Magenta", hex: "#ff00c8" },
  { name: "Off", hex: "#000000" }
]

function swatches(accentHex) {
  var list = []
  var accent = hexOf(accentHex)
  if (accent !== "") list.push({ name: "Theme accent", hex: accent, accent: true })
  for (var i = 0; i < PRESETS.length; i++) list.push(PRESETS[i])
  return list
}

// ---- Device helpers -------------------------------------------------------

function hasColorMode(dev) {
  if (!dev || !dev.modes) return false
  for (var i = 0; i < dev.modes.length; i++) if (dev.modes[i].acceptsColor) return true
  return false
}

// A mode named Off that takes no color. Only the last resort for turning a
// device dark: painting black through a color mode is preferred, because an
// Off mode may silence the ARGB data line and hand fans with their own
// fallback controller over to their built-in rainbow.
function offModeIndex(dev) {
  if (!dev || !dev.modes) return -1
  for (var i = 0; i < dev.modes.length; i++) {
    var m = dev.modes[i]
    if (String(m.name).trim().toLowerCase() === "off" && m.colorModeName === "none") return i
  }
  return -1
}

function activeMode(dev) {
  if (!dev || !dev.modes) return null
  var i = dev.activeMode
  if (typeof i !== "number" || i < 0 || i >= dev.modes.length) return null
  return dev.modes[i]
}

// Identity that survives a reboot. Two sticks of the same model share a name,
// so an I2C address is kept. A USB path is not, because hidraw nodes move.
function deviceKey(dev) {
  if (!dev) return ""
  var name = String(dev.name || "")
  var match = /address\s+(0x[0-9a-fA-F]+)/.exec(String(dev.location || ""))
  return match ? name + "@" + match[1].toLowerCase() : name
}

// The off-map key holding this device's entry: its own key, or its bare name
// for an entry written before keys carried the I2C address. "" when off has
// nothing for it.
function offKey(map, dev) {
  if (!map || !dev) return ""
  var key = deviceKey(dev)
  if (key !== "" && map[key] !== undefined) return key
  var name = String(dev.name || "")
  if (name !== "" && map[name] !== undefined) return name
  return ""
}

// Keys inside `lit` are device names (`ENE DRAM@0x71`, names with spaces).
// A `var` property that arrived from shell.json is sometimes a map whose
// bracket lookup hides those keys, while for-in still lists them. Round-trip
// through JSON so later lookups see a real object.
function objectKeys(value) {
  var out = []
  if (!value || typeof value !== "object") return out
  var seen = ({})
  var listed = []
  try { listed = Object.keys(value) } catch (e) { listed = [] }
  var i
  for (i = 0; i < listed.length; i++) {
    out.push(String(listed[i]))
    seen[String(listed[i])] = true
  }
  for (var k in value) {
    if (seen[String(k)]) continue
    out.push(String(k))
    seen[String(k)] = true
  }
  return out
}

function plain(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return ({})
  try {
    var text = JSON.stringify(value)
    if (text && text.charAt(0) === "{") {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed
    }
  } catch (e) {}
  var copy = ({})
  var keys = objectKeys(value)
  for (var i = 0; i < keys.length; i++) copy[keys[i]] = value[keys[i]]
  return copy
}

function modeByName(dev, name) {
  if (!dev || !dev.modes || !name) return null
  for (var i = 0; i < dev.modes.length; i++) if (dev.modes[i].name === name) return dev.modes[i]
  return null
}

// Exact key, then a unique name match, then the Razer dongle case where the
// same device is "Keyboard" or "Keyboard (Mouse)" depending on what else was
// awake when OpenRGB enumerated it.
function lookupSnap(lit, dev) {
  lit = plain(lit)
  if (!dev) return null
  var key = deviceKey(dev)
  if (key !== "" && lit[key]) return lit[key]
  var name = String(dev.name || "")
  var byName = []
  var byPrefix = []
  var keys = objectKeys(lit)
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i]
    if (k === key && lit[k]) return lit[k]
    if (name !== "" && k === name) byName.push(lit[k])
    else if (name !== "" && (k.indexOf(name + " (") === 0 || name.indexOf(k + " (") === 0))
      byPrefix.push(lit[k])
  }
  if (byName.length === 1) return byName[0]
  if (byPrefix.length === 1) return byPrefix[0]
  return null
}

function snapMatches(dev, snap) {
  if (!dev || !snap) return false
  var modeName = snap.mode ? String(snap.mode) : ""
  var color = hexOf(snap.color)
  var mode = modeByName(dev, modeName)
  var current = activeMode(dev)
  if (modeName !== "" && (!current || current.name !== modeName)) return false
  if (color !== "" && hexOf(dev.color) !== color) return false
  var target = mode || current
  if (target && target.hasBrightness && typeof snap.brightness === "number"
      && Number(target.brightness) !== Number(snap.brightness)) return false
  if (target && target.hasSpeed && typeof snap.speed === "number"
      && Number(target.speed) !== Number(snap.speed)) return false
  return true
}

// What to put back after OpenRGB starts again. Direct, and plenty of other
// modes, cannot be written to the device, so this is the copy that lasts.
// `overrides.brightness === false` leaves brightness out: the global dimmer
// owns it, and a dimmed read-back must not be stored as the user's setting.
function lightingSnapshot(dev, overrides) {
  overrides = overrides || ({})
  var named = overrides.mode ? modeByName(dev, String(overrides.mode)) : null
  var mode = named || activeMode(dev)
  var snap = ({})
  if (mode && mode.name) snap.mode = String(mode.name)
  else if (overrides.mode) snap.mode = String(overrides.mode)
  if (!mode || mode.acceptsColor) {
    var color = hexOf(overrides.color !== undefined ? overrides.color : (dev ? dev.color : ""))
    if (color !== "") snap.color = color
  }
  if (mode && mode.hasBrightness && overrides.brightness !== false) {
    var brightness = typeof overrides.brightness === "number" ? overrides.brightness : mode.brightness
    if (typeof brightness === "number") snap.brightness = Math.round(brightness)
  }
  if (mode && mode.hasSpeed) {
    var speed = typeof overrides.speed === "number" ? overrides.speed : mode.speed
    if (typeof speed === "number") snap.speed = Math.round(speed)
  }
  return snap
}

// Copy `lit`, then record `accent` on every device that is not switched off.
// `overrideFor(dev)` supplies a color or mode just chosen for one device;
// everyone else keeps the accent, and off devices keep the entry they had.
function litKeepingAccent(lit, devices, accent, offMap, overrideFor, omitBrightness) {
  var next = plain(lit)
  offMap = plain(offMap)
  var accentHex = hexOf(accent)
  devices = devices || []
  for (var i = 0; i < devices.length; i++) {
    var dev = devices[i]
    var key = deviceKey(dev)
    if (!dev || key === "") continue
    if (offKey(offMap, dev) !== "") continue
    var chosen = null
    if (typeof overrideFor === "function") chosen = overrideFor(dev)
    var override = ({})
    if (chosen) {
      if (chosen.mode !== undefined) override.mode = chosen.mode
      if (chosen.color !== undefined) override.color = chosen.color
      if (typeof chosen.brightness === "number") override.brightness = chosen.brightness
      if (typeof chosen.speed === "number") override.speed = chosen.speed
    } else if (accentHex !== "") {
      override.color = accentHex
    }
    if (omitBrightness) override.brightness = false
    next[key] = lightingSnapshot(dev, override)
  }
  return next
}

function modeOptions(dev) {
  var out = []
  if (!dev || !dev.modes) return out
  for (var i = 0; i < dev.modes.length; i++) out.push({ value: String(i), label: dev.modes[i].name })
  return out
}

// One color for the bar: what the devices agree on, else the first one that
// has a color at all. Empty when nothing is lit.
function summaryColor(devices) {
  if (!devices || !devices.length) return ""
  var first = ""
  for (var i = 0; i < devices.length; i++) {
    var c = hexOf(devices[i].color)
    if (c === "" || c === "#000000") continue
    if (first === "") first = c
  }
  return first
}

function plural(n, singular, pluralForm) {
  return n + " " + (n === 1 ? singular : (pluralForm || singular + "s"))
}

// Device rows lead with the model, not the brand: the vendor prefix is
// stripped when the name repeats it, so "SteelSeries Apex Pro TKL" fits as
// "Apex Pro TKL" instead of truncating the part that matters.
function displayName(dev) {
  if (!dev) return ""
  var name = String(dev.name || "").trim()
  var vendor = String(dev.vendor || "").trim()
  if (vendor !== "" && name.toLowerCase().indexOf(vendor.toLowerCase() + " ") === 0)
    name = name.slice(vendor.length + 1).trim()
  return name !== "" ? name : vendor
}

function deviceSubtitle(dev) {
  if (!dev) return ""
  var mode = activeMode(dev)
  var parts = [typeLabel(dev.typeName)]
  if (mode) parts.push(mode.name)
  if (dev.ledCount) parts.push(plural(dev.ledCount, "LED"))
  return parts.join(" · ")
}
