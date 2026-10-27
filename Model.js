// Pure helpers for the oma-hevy panel. Kept free of QML objects so they can be
// unit-tested with node (see `make test` in the README).

function parseSnapshot(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    return (data && typeof data === "object") ? data : null
  } catch (e) {
    return null
  }
}

function isAuthError(snapshot) {
  return !!(snapshot && snapshot.error === "not_authenticated")
}

function hasData(snapshot) {
  return !!(snapshot && !snapshot.error)
}

function unitOf(snapshot) {
  return snapshot && snapshot.user && snapshot.user.weight_unit === "lbs" ? "lbs" : "kg"
}

function parseNumber(value) {
  var n = parseFloat(value)
  return isFinite(n) ? n : null
}

// Splits a kg value into a big display value plus its unit, respecting the
// weight unit picked in Hevy (the API always returns kilograms).
function volumeParts(kg, unit) {
  var n = parseNumber(kg)
  if (n === null || n < 0) n = 0

  if (unit === "lbs") {
    var lb = n * 2.2046226
    if (lb >= 10000) return { value: (lb / 1000).toFixed(1), unit: "k lb" }
    if (lb >= 1000) return { value: Math.round(lb).toLocaleString("en-US"), unit: "lb" }
    return { value: String(Math.round(lb)), unit: "lb" }
  }

  if (n >= 1000) return { value: (n / 1000).toFixed(1), unit: "t" }
  return { value: String(Math.round(n)), unit: "kg" }
}

function volumeShort(kg, unit) {
  var parts = volumeParts(kg, unit)
  return parts.value + parts.unit
}

function weightLabel(kg, unit) {
  var n = parseNumber(kg)
  if (n === null) return "—"
  if (unit === "lbs") return Math.round(n * 2.2046226) + " lb"
  var rounded = Math.round(n * 10) / 10
  return (rounded % 1 === 0 ? String(rounded) : rounded.toFixed(1)) + " kg"
}

function numberLabel(value) {
  var n = parseNumber(value)
  if (n === null) return "—"
  return String(Math.round(n))
}

function percentLabel(value) {
  var n = parseNumber(value)
  return n === null ? "—" : Math.round(n) + "%"
}

function durationLabel(seconds) {
  var n = parseNumber(seconds)
  if (n === null || n <= 0) return "—"
  var minutes = Math.round(n / 60)
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours <= 0) return rest + "m"
  return hours + "h " + (rest < 10 ? "0" + rest : rest) + "m"
}

function deltaLabel(pct) {
  var n = parseNumber(pct)
  if (n === null) return ""
  return (n >= 0 ? "+" : "") + (Math.round(n * 10) / 10) + "%"
}

function dateLabel(iso) {
  if (!iso) return ""
  var d = new Date(iso)
  if (isNaN(d.getTime())) return ""
  return Qt.formatDateTime(d, "ddd d MMM")
}

function dayLabel(iso) {
  if (!iso) return ""
  var d = new Date(iso + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  return Qt.formatDateTime(d, "dd")
}

function weekdayLabel(iso) {
  if (!iso) return ""
  var d = new Date(iso + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  return Qt.formatDateTime(d, "ddd").slice(0, 2)
}

function monthLabel(iso) {
  if (!iso) return ""
  var d = new Date(iso + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  return Qt.formatDateTime(d, "MMM")
}

// "just now", "3 min ago", "2 hr ago", "yesterday", "4 days ago"
function relativeUpdated(fetchedAtSeconds, nowSeconds) {
  var then = parseNumber(fetchedAtSeconds)
  var now = parseNumber(nowSeconds)
  if (then === null || now === null || then <= 0) return ""
  var delta = Math.max(0, now - then)
  if (delta < 60) return "just now"
  var minutes = Math.round(delta / 60)
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + " hr ago"
  var days = Math.round(hours / 24)
  return days === 1 ? "yesterday" : days + " days ago"
}

// Normalises an array of values into pixel heights for the bar charts.
function barHeights(values, maxHeight) {
  var peak = 0
  var rows = []
  for (var i = 0; i < values.length; i++) {
    var n = parseNumber(values[i])
    if (n === null || n < 0) n = 0
    rows.push(n)
    if (n > peak) peak = n
  }
  var heights = []
  for (var j = 0; j < rows.length; j++) {
    heights.push(peak <= 0 ? 0 : Math.max(2, Math.round((rows[j] / peak) * maxHeight)))
  }
  return heights
}

function muscleWidth(pct) {
  var n = parseNumber(pct)
  if (n === null) return 0
  return Math.max(2, Math.min(100, n))
}

function truncate(text, maxLen) {
  var s = String(text || "")
  return s.length > maxLen ? s.slice(0, maxLen - 1) + "…" : s
}

if (typeof module !== "undefined") {
  module.exports = {
    parseSnapshot: parseSnapshot,
    isAuthError: isAuthError,
    hasData: hasData,
    unitOf: unitOf,
    volumeParts: volumeParts,
    volumeShort: volumeShort,
    weightLabel: weightLabel,
    numberLabel: numberLabel,
    percentLabel: percentLabel,
    durationLabel: durationLabel,
    deltaLabel: deltaLabel,
    dateLabel: dateLabel,
    dayLabel: dayLabel,
    weekdayLabel: weekdayLabel,
    monthLabel: monthLabel,
    relativeUpdated: relativeUpdated,
    barHeights: barHeights,
    muscleWidth: muscleWidth,
    truncate: truncate
  }
}
