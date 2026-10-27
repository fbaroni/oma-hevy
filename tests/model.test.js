const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("parseSnapshot rejects junk", () => {
  assert.equal(Model.parseSnapshot(""), null)
  assert.equal(Model.parseSnapshot("{nope"), null)
  assert.deepEqual(Model.parseSnapshot('{"a":1}'), { a: 1 })
})

test("volumeParts switches to tonnes above 1t", () => {
  assert.deepEqual(Model.volumeParts(842, "kg"), { value: "842", unit: "kg" })
  assert.deepEqual(Model.volumeParts(18400, "kg"), { value: "18.4", unit: "t" })
  assert.deepEqual(Model.volumeParts(0, "kg"), { value: "0", unit: "kg" })
})

test("volumeParts respects the Hevy weight unit", () => {
  assert.deepEqual(Model.volumeParts(100, "lbs"), { value: "220", unit: "lb" })
  assert.deepEqual(Model.volumeParts(10000, "lbs"), { value: "22.0", unit: "k lb" })
  assert.equal(Model.volumeShort(18400, "kg"), "18.4t")
})

test("weightLabel keeps half-kilo precision only when needed", () => {
  assert.equal(Model.weightLabel(92.5, "kg"), "92.5 kg")
  assert.equal(Model.weightLabel(120, "kg"), "120 kg")
  assert.equal(Model.weightLabel(92.5, "lbs"), "204 lb")
  assert.equal(Model.weightLabel(null, "kg"), "—")
})

test("durationLabel reads like a human", () => {
  assert.equal(Model.durationLabel(4380), "1h 13m")
  assert.equal(Model.durationLabel(300), "5m")
  assert.equal(Model.durationLabel(0), "—")
})

test("deltaLabel signs percentages", () => {
  assert.equal(Model.deltaLabel(10.74), "+10.7%")
  assert.equal(Model.deltaLabel(-100), "-100%")
  assert.equal(Model.deltaLabel(null), "")
})

test("relativeUpdated buckets time sensibly", () => {
  assert.equal(Model.relativeUpdated(0, 1000), "")
  assert.equal(Model.relativeUpdated(970, 1000), "just now")
  assert.equal(Model.relativeUpdated(880, 1000), "2 min ago")
  assert.equal(Model.relativeUpdated(10000 - 3900, 10000), "1 hr ago")
  assert.equal(Model.relativeUpdated(100000 - 90000, 100000), "yesterday")
})

test("barHeights normalises to a pixel axis", () => {
  assert.deepEqual(Model.barHeights([0, 10, 5], 100), [2, 100, 50])
  assert.deepEqual(Model.barHeights([], 100), [])
  assert.deepEqual(Model.barHeights([null, 0], 10), [0, 0])
})

test("muscleWidth clamps and gives tiny slices a visible bar", () => {
  assert.equal(Model.muscleWidth(0), 2)
  assert.equal(Model.muscleWidth(33.3), 33.3)
  assert.equal(Model.muscleWidth(140), 100)
})

test("truncate never exceeds the budget", () => {
  assert.equal(Model.truncate("abcdef", 4), "abc…")
  assert.equal(Model.truncate("ab", 4), "ab")
  assert.equal(Model.truncate(null, 4), "")
})

test("shortDate does not depend on Qt", () => {
  assert.equal(Model.shortDate("2026-10-14"), "14 Oct")
  assert.equal(Model.shortDate("2026-01-05T10:00:00+01:00"), "5 Jan")
  assert.equal(Model.shortDate("junk"), "")
  assert.equal(Model.shortDate(null), "")
})

test("setLabel reads like a logged set", () => {
  assert.equal(Model.setLabel(60, 8, "kg"), "60 kg × 8")
  assert.equal(Model.setLabel(0, 12, "kg"), "12 reps")
  assert.equal(Model.setLabel(null, 8, "kg"), "—")
})

test("sparkline scales to its own range and handles flat and single points", () => {
  const pts = Model.sparkline([10, 20, 30], 100, 20, 0)
  assert.deepEqual(pts.map(p => p.x), [0, 50, 100])
  assert.equal(pts[0].y, 20)          // lowest value at the bottom
  assert.equal(pts[2].y, 0)           // highest at the top
  assert.equal(Model.sparkline([5, 5], 100, 20, 0)[0].y, 10)
  assert.equal(Model.sparkline([7], 100, 20)[0].x, 50)
  assert.deepEqual(Model.sparkline([], 100, 20), [])
  assert.equal(Model.sparkline([1, null, 3], 100, 20).length, 2)
})

test("heatAlpha brightens up to a solid week and not beyond", () => {
  assert.ok(Model.heatAlpha(0) < Model.heatAlpha(3))
  assert.ok(Model.heatAlpha(3) < Model.heatAlpha(8))
  assert.ok(Model.heatAlpha(8) < Model.heatAlpha(14))
  assert.ok(Model.heatAlpha(30) <= Model.heatAlpha(14))
})

test("changeTone has a dead band", () => {
  assert.equal(Model.changeTone(12), "up")
  assert.equal(Model.changeTone(-6), "down")
  assert.equal(Model.changeTone(1.5), "flat")
  assert.equal(Model.changeTone(null), "flat")
})

test("barShare and sumOf work on lists of rows", () => {
  const rows = [{ n: 2 }, { n: 8 }, { n: 4 }]
  assert.equal(Model.barShare(rows, "n", 4), 0.5)
  assert.equal(Model.barShare([], "n", 4), 0)
  assert.equal(Model.sumOf(rows, "n"), 14)
})

test("recentAverage skips the week in progress", () => {
  assert.equal(Model.recentAverage([9, 5, 0, 3, 0, 3, 3, 0]), 2.25)
  assert.equal(Model.recentAverage([4]), 0)
  assert.equal(Model.recentAverage(null), 0)
})
