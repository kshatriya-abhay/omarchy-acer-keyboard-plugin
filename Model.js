// Pure helpers for the keyboard RGB panel. No state — anything stateful
// belongs on Panel.qml.

function clampByte(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(255, Math.round(n)))
}

function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 100
  return Math.max(0, Math.min(100, Math.round(n)))
}

function clampSpeed(value) {
  var n = Number(value)
  if (!isFinite(n)) return 4
  return Math.max(0, Math.min(9, Math.round(n)))
}

function clampDirection(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return n === 2 ? 2 : 1
}

function toHex(value) {
  var s = clampByte(value).toString(16)
  return s.length < 2 ? "0" + s : s
}

function rgbToHex(r, g, b) {
  return "#" + toHex(r) + toHex(g) + toHex(b)
}

// Parse a user-typed hex color. Accepts "#rrggbb", "rrggbb", and 3-digit
// shorthand. Returns null when the input isn't a valid hex color.
function hexToRgb(hex) {
  var h = String(hex || "").trim().replace(/^#/, "")
  var match = h.match(/^([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/)
  if (!match) return null
  if (h.length === 3) {
    h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2)
  }
  return {
    r: parseInt(h.slice(0, 2), 16),
    g: parseInt(h.slice(2, 4), 16),
    b: parseInt(h.slice(4, 6), 16)
  }
}

function isValidHex(hex) {
  return hexToRgb(hex) !== null
}

// ---- modes ----------------------------------------------------------------
// Mode codes match the upstream facer_rgb.py payload byte[0]. The ordered list
// drives the 2x3 grid (rows of 3) in Panel.qml.

var MODE_CODES = { static: 0, breath: 1, neon: 2, wave: 3, shift: 4, zoom: 5 }

var MODES = [
  { name: "static", label: "Static" },
  { name: "breath", label: "Breath" },
  { name: "neon", label: "Neon" },
  { name: "wave", label: "Wave" },
  { name: "shift", label: "Shifting" },
  { name: "zoom", label: "Zoom" }
]

function modeName(code) {
  for (var i = 0; i < MODES.length; i++) {
    if (MODE_CODES[MODES[i].name] === code) return MODES[i].name
  }
  return "static"
}

function modeCode(name) {
  return MODE_CODES[name] !== undefined ? MODE_CODES[name] : 0
}

function modeLabel(name) {
  for (var i = 0; i < MODES.length; i++) {
    if (MODES[i].name === name) return MODES[i].label
  }
  return name
}

function isDynamic(mode) {
  return mode !== "static"
}

function usesColor(mode) {
  return mode === "static" || mode === "breath" || mode === "shift" || mode === "zoom"
}

function usesDirection(mode) {
  return mode === "wave" || mode === "shift"
}

// ---- zones (static only) ---------------------------------------------------
// The AN515-57 backlight has 4 zones (bitmasks 1,2,4,8). Per-zone color only
// applies to static mode; dynamic modes carry a single RGB triplet. The ordered
// list drives the 1x5 zone button row (All + four zone numbers) in Panel.qml.

var ZONES = [
  { value: "all", label: "All" },
  { value: "1", label: "1" },
  { value: "2", label: "2" },
  { value: "3", label: "3" },
  { value: "4", label: "4" }
]

function clampZone(value) {
  for (var i = 0; i < ZONES.length; i++) {
    if (ZONES[i].value === value) return value
  }
  return "all"
}

function zoneTriplets(raw, r, g, b) {
  var out = []
  var i
  for (i = 0; i < 4; i++) {
    var t = raw && raw[i] ? raw[i] : null
    out.push([
      clampByte(t && t[0] !== undefined ? t[0] : r),
      clampByte(t && t[1] !== undefined ? t[1] : g),
      clampByte(t && t[2] !== undefined ? t[2] : b)
    ])
  }
  return out
}

function parseState(raw) {
  var state = {
    mode: "static",
    brightness: 100,
    r: 255,
    g: 255,
    b: 255,
    speed: 4,
    direction: 1,
    poweredOn: true,
    lastBrightness: 100,
    zone: "all",
    zones: [[255, 255, 255], [255, 255, 255], [255, 255, 255], [255, 255, 255]]
  }
  try {
    var parsed = raw ? JSON.parse(String(raw)) : {}
    var m = parsed.mode
    if (MODE_CODES[m] !== undefined) state.mode = m
    else {
      var num = Number(m)
      state.mode = isFinite(num) ? modeName(num) : "static"
    }
    state.brightness = clampBrightness(parsed.brightness)
    state.r = clampByte(parsed.r)
    state.g = clampByte(parsed.g)
    state.b = clampByte(parsed.b)
    state.speed = clampSpeed(parsed.speed)
    state.direction = clampDirection(parsed.direction)
    state.poweredOn = parsed.poweredOn !== false
    state.lastBrightness = clampBrightness(parsed.lastBrightness)
    state.zone = clampZone(parsed.zone)
    state.zones = zoneTriplets(parsed.zones, state.r, state.g, state.b)
  } catch (e) {}
  return state
}

if (typeof module !== "undefined") {
  module.exports = {
    clampByte: clampByte,
    clampBrightness: clampBrightness,
    clampSpeed: clampSpeed,
    clampDirection: clampDirection,
    toHex: toHex,
    rgbToHex: rgbToHex,
    hexToRgb: hexToRgb,
    isValidHex: isValidHex,
    MODE_CODES: MODE_CODES,
    MODES: MODES,
    ZONES: ZONES,
    modeName: modeName,
    modeCode: modeCode,
    modeLabel: modeLabel,
    isDynamic: isDynamic,
    usesColor: usesColor,
    usesDirection: usesDirection,
    clampZone: clampZone,
    zoneTriplets: zoneTriplets,
    parseState: parseState
  }
}
