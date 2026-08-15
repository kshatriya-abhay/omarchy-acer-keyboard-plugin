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

function parseState(raw) {
  var state = { brightness: 100, r: 255, g: 255, b: 255, poweredOn: true, lastBrightness: 100 }
  try {
    var parsed = raw ? JSON.parse(String(raw)) : {}
    state.brightness = clampBrightness(parsed.brightness)
    state.r = clampByte(parsed.r)
    state.g = clampByte(parsed.g)
    state.b = clampByte(parsed.b)
    state.poweredOn = parsed.poweredOn !== false
    state.lastBrightness = clampBrightness(parsed.lastBrightness)
  } catch (e) {}
  return state
}

if (typeof module !== "undefined") {
  module.exports = {
    clampByte: clampByte,
    clampBrightness: clampBrightness,
    toHex: toHex,
    rgbToHex: rgbToHex,
    hexToRgb: hexToRgb,
    isValidHex: isValidHex,
    parseState: parseState
  }
}
