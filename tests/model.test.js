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
