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

test("brightnessColorMap never flattens a multi-color device", () => {
  const { brightnessColorMap } = context
  const devices = [
    { index: 0, name: "Keyboard", location: "HID: /dev/hidraw3", color: "#ff0000", uniform: true },
    { index: 1, name: "Strip", location: "", color: "#ff0000", uniform: false },
    { index: 2, ...stick("0x71"), color: "#00ff00", uniform: true },
    { index: 3, ...stick("0x73"), color: "#00ff00", uniform: true },
  ]
  const map = brightnessColorMap(devices, { "ENE DRAM@0x73": "#0000ff", Strip: "#abcdef" })
  assert.equal(map["0"], "#ff0000")
  assert.equal(map["1"], "#abcdef")
  assert.equal(map["2"], "#00ff00")
  assert.equal(map["3"], "#0000ff")
  assert.equal(brightnessColorMap(devices, {})["1"], undefined)
})

const { plain, objectKeys, lookupSnap, snapMatches, lightingSnapshot, litKeepingAccent } = context

test("plain keeps keys that are not identifiers", () => {
  const lit = { "ENE DRAM@0x71": { mode: "Static", color: "#00e5ff" } }
  const copy = plain(lit)
  assert.equal(copy["ENE DRAM@0x71"].color, "#00e5ff")
  assert.ok(objectKeys(copy).indexOf("ENE DRAM@0x71") !== -1)
})

test("lookupSnap finds a razer device whose dongle suffix changed", () => {
  const saved = "Razer DeathStalker V2 Pro TKL (Wireless) (Razer Basilisk V3 Pro (Wireless))"
  const lit = { [saved]: { mode: "Direct", color: "#00e5ff", brightness: 255 } }
  const dev = { name: "Razer DeathStalker V2 Pro TKL (Wireless)", location: "HID: /dev/hidraw0" }
  assert.equal(lookupSnap(lit, dev).color, "#00e5ff")
})

test("lookupSnap does not cross two dram sticks", () => {
  const lit = {
    "ENE DRAM@0x71": { mode: "Static", color: "#00e5ff" },
    "ENE DRAM@0x73": { mode: "Static", color: "#ff00c8" },
  }
  const a = { name: "ENE DRAM", location: "I2C: bus, address 0x71" }
  const b = { name: "ENE DRAM", location: "I2C: bus, address 0x73" }
  assert.equal(lookupSnap(lit, a).color, "#00e5ff")
  assert.equal(lookupSnap(lit, b).color, "#ff00c8")
})

test("snapMatches requires mode, color, and brightness", () => {
  const dev = {
    color: "#ff00c8",
    activeMode: 0,
    modes: [{ name: "Static", hasBrightness: true, brightness: 10, hasSpeed: false }],
  }
  assert.equal(snapMatches(dev, { mode: "Static", color: "#ff00c8", brightness: 10 }), true)
  assert.equal(snapMatches(dev, { mode: "Static", color: "#ff00c8", brightness: 4 }), false)
  assert.equal(snapMatches(dev, { mode: "Direct", color: "#ff00c8" }), false)
  assert.equal(snapMatches(dev, { mode: "Static", color: "#00e5ff", brightness: 10 }), false)
})

test("lightingSnapshot can leave brightness out for the global dimmer", () => {
  const dev = {
    color: "#00e5ff",
    activeMode: 0,
    modes: [{ name: "Static", acceptsColor: true, hasBrightness: true, brightness: 4, hasSpeed: false }],
  }
  assert.equal(lightingSnapshot(dev, { brightness: false }).brightness, undefined)
  assert.equal(lightingSnapshot(dev, {}).brightness, 4)
})

test("litKeepingAccent leaves an off device alone and keeps the accent on the rest", () => {
  const keyboard = {
    name: "Keyboard",
    location: "HID: /dev/hidraw0",
    color: "#111111",
    activeMode: 0,
    modes: [{ name: "Direct", acceptsColor: true, hasBrightness: true, brightness: 255, hasSpeed: false }],
  }
  const dram = {
    name: "ENE DRAM",
    location: "I2C: bus, address 0x71",
    color: "#222222",
    activeMode: 0,
    modes: [{ name: "Static", acceptsColor: true, hasBrightness: false, hasSpeed: false }],
  }
  const gpu = {
    name: "GPU",
    location: "I2C: bus, address 0x75",
    color: "#333333",
    activeMode: 0,
    modes: [{ name: "Static", acceptsColor: true, hasBrightness: true, brightness: 10, hasSpeed: false }],
  }
  const lit = {
    Keyboard: { mode: "Direct", color: "#00e5ff", brightness: 255 },
    "ENE DRAM@0x71": { mode: "Static", color: "#00e5ff" },
    "GPU@0x75": { mode: "Static", color: "#ff00c8", brightness: 10 },
  }
  const off = { "GPU@0x75": { mode: 0, color: "#333333" } }
  const next = litKeepingAccent(lit, [keyboard, dram, gpu], "#aabbcc", off, (dev) => {
    return dev.name === "Keyboard" ? { color: "#ff0000" } : null
  })
  assert.equal(next.Keyboard.color, "#ff0000")
  assert.equal(next.Keyboard.mode, "Direct")
  assert.equal(next["ENE DRAM@0x71"].color, "#aabbcc")
  assert.equal(next["ENE DRAM@0x71"].mode, "Static")
  assert.equal(next["GPU@0x75"].color, "#ff00c8")
  assert.equal(next["GPU@0x75"].brightness, 10)
})
