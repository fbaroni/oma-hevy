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

// ------------------------------------------------------------ deep dive

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var TIME_LABELS = { night: "Night", morning: "Morning", midday: "Midday", afternoon: "Afternoon", evening: "Evening" }

// "2026-10-14" -> "14 Oct", without Qt so it can be unit-tested.
function shortDate(iso) {
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""))
  if (!m) return ""
  return parseInt(m[3], 10) + " " + MONTHS[parseInt(m[2], 10) - 1]
}

function timeLabel(key) {
  return TIME_LABELS[key] || String(key || "")
}

// "60 kg × 8" (or lb), the way a set reads in the Hevy app.
function setLabel(weightKg, reps, unit) {
  var w = parseNumber(weightKg), r = parseNumber(reps)
  if (w === null || r === null) return "—"
  return w > 0 ? weightLabel(w, unit) + " × " + Math.round(r) : Math.round(r) + " reps"
}

// A series scaled to its own range, as pixel points for a sparkline.
function sparkline(series, width, height, pad) {
  var values = [], i, n
  for (i = 0; i < series.length; i++) {
    n = parseNumber(series[i])
    if (n !== null) values.push(n)
  }
  if (values.length === 0) return []
  var lo = Math.min.apply(null, values), hi = Math.max.apply(null, values)
  var margin = pad === undefined ? 2 : pad
  var span = hi - lo
  var out = []
  for (i = 0; i < values.length; i++) {
    var x = values.length === 1 ? width / 2 : (i / (values.length - 1)) * width
    var frac = span > 0 ? (values[i] - lo) / span : 0.5
    out.push({ x: x, y: margin + (1 - frac) * Math.max(0, height - margin * 2) })
  }
  return out
}

// How hard a muscle group was worked in a week: 0 sets is empty, 10-20 a
// solid week, more than 20 still strong but no brighter.
function heatAlpha(sets) {
  var n = parseNumber(sets) || 0
  if (n <= 0) return 0.05
  if (n < 6) return 0.26
  if (n < 10) return 0.5
  if (n <= 20) return 0.88
  return 0.7
}

// "up", "down" or "flat" for a percentage change, with a 2% dead band.
function changeTone(pct) {
  var n = parseNumber(pct)
  if (n === null || Math.abs(n) < 2) return "flat"
  return n > 0 ? "up" : "down"
}

// Fraction of the largest value in list[key], for horizontal bars.
function barShare(list, key, value) {
  var peak = 0
  for (var i = 0; i < list.length; i++) peak = Math.max(peak, parseNumber(list[i][key]) || 0)
  var n = parseNumber(value) || 0
  return peak > 0 ? n / peak : 0
}

function sumOf(list, key) {
  var total = 0
  for (var i = 0; i < list.length; i++) total += parseNumber(list[i][key]) || 0
  return total
}

// Four-week average of a muscle row, ignoring the week still in progress.
function recentAverage(weeks) {
  if (!weeks || weeks.length < 2) return 0
  var slice = weeks.slice(Math.max(0, weeks.length - 5), weeks.length - 1)
  var total = 0
  for (var i = 0; i < slice.length; i++) total += parseNumber(slice[i]) || 0
  return slice.length ? total / slice.length : 0
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
    truncate: truncate,
    shortDate: shortDate,
    timeLabel: timeLabel,
    setLabel: setLabel,
    sparkline: sparkline,
    heatAlpha: heatAlpha,
    changeTone: changeTone,
    barShare: barShare,
    sumOf: sumOf,
    recentAverage: recentAverage
  }
}
