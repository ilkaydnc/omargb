// Model.js is a QML pragma library; this loads it as a plain script and
// checks the pure functions. Run with: node --test tests/*.mjs
import fs from "fs"
import vm from "vm"
import { test } from "node:test"
import assert from "node:assert/strict"

const src = fs.readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/, "")
const context = {}
vm.createContext(context)
vm.runInContext(src, context)

const { deviceKey, offKey } = context

const stick = (addr) => ({
  name: "ENE DRAM",
  location: `I2C: SMBus PIIX4 adapter port 0 at 0b00 (/dev/i2c-11), address ${addr}`,
})

test("deviceKey tells two sticks of the same model apart", () => {
  assert.equal(deviceKey(stick("0x71")), "ENE DRAM@0x71")
  assert.equal(deviceKey(stick("0x73")), "ENE DRAM@0x73")
  assert.equal(deviceKey(stick("0x7A")), "ENE DRAM@0x7a")
})

test("deviceKey ignores a hidraw path, which moves across reboots", () => {
  assert.equal(deviceKey({ name: "Razer Nommo", location: "HID: /dev/hidraw5" }), "Razer Nommo")
  assert.equal(deviceKey({ name: "Strip", location: "" }), "Strip")
  assert.equal(deviceKey(null), "")
})

test("offKey finds each stick under its own key", () => {
  const off = { "ENE DRAM@0x71": { mode: 0 }, "ENE DRAM@0x73": { mode: 1 } }
  assert.equal(offKey(off, stick("0x71")), "ENE DRAM@0x71")
  assert.equal(offKey(off, stick("0x73")), "ENE DRAM@0x73")
  assert.equal(offKey({ "ENE DRAM@0x71": {} }, stick("0x73")), "")
})

test("offKey still finds an entry saved under the bare name", () => {
  assert.equal(offKey({ "ENE DRAM": { mode: 0 } }, stick("0x71")), "ENE DRAM")
  assert.equal(offKey({}, stick("0x71")), "")
  assert.equal(offKey(null, stick("0x71")), "")
})
