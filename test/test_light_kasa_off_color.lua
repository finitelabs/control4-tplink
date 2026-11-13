-- The TP-Link Light on the Kasa rig, which drops the color a set that turns it off carries, as dev's KL135 did:
-- under Dim-To-Warm an off from 25 % is sent with no color, the proxy is told the Dim color once and a poll tells it
-- nothing more, and the next on carries its color to the bulb.

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local D = require("light_drivers")
local Light = require("lib.light")

local KASA = "Kasa bulb on the legacy port"

local rig
for _, r in ipairs(require("light_rigs").rigs.tplink_light) do
  if r.name == KASA then
    rig = r
  end
end
rig.folder = "tplink_light"

local clock = F.virtualClock()
local p = P.install(clock, {})
local xml = D.xml(D.root(), rig.folder) or ""
D.seedProperties(xml)
local restoreConfig = D.answerConfig(xml)
local h = { clock = clock, proxy = p, errors = {}, lo = 1, hi = 100 }
local before = #Light.made
h.device = rig.load(h, { on = false, level = 0.5 })
h.light = Light.made[#Light.made]
T.check("the rig makes a light", #Light.made > before)

-- What the driver sends the bulb, as the adapter is handed it.
local A = package.loaded["tplink.light_adapter"]
local sendNow, sent = A.sendNow, {}
A.sendNow = function(self, opts)
  sent[#sent + 1] = opts
  return sendNow(self, opts)
end
clock.run(17000)

local onX, onY = C4:ColorCCTtoXY(5000)
local dimX, dimY = C4:ColorCCTtoXY(2200)
p:send("UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = 1,
  COLOR_PRESET_ORIGIN = 1,
  COLOR_PRESET_COLOR_X = onX,
  COLOR_PRESET_COLOR_Y = onY,
  COLOR_PRESET_COLOR_MODE = 1,
  COLOR_FADE_PRESET_ID = 2,
  COLOR_FADE_PRESET_ORIGIN = 1,
  COLOR_FADE_PRESET_COLOR_X = dimX,
  COLOR_FADE_PRESET_COLOR_Y = dimY,
  COLOR_FADE_PRESET_COLOR_MODE = 1,
})
clock.run(1000)

T.section("An off under Dim-To-Warm from 25 %")

p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 25, RATE = 0 })
clock.run(3000)
local lit = h.device.state()
T.check(
  "the bulb is lit at 25 % in a white between the Dim and On colors",
  lit.on and lit.color.kelvin ~= nil and lit.color.kelvin > 2200 and lit.color.kelvin < 5000,
  lit.color.kelvin
)

p:mark()
sent = {}
p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
clock.run(20000)
T.eq(
  "the off is sent alone, with no color",
  { #sent, sent[1].state, sent[1].has_color_temperature or sent[1].has_rgb or false },
  { 1, false, false }
)
local off = h.device.state()
T.eq("the bulb is off in the white it was lit in", { off.on, off.color.kelvin }, { false, lit.color.kelvin })
local told = p:told("LIGHT_COLOR_CHANGED")
T.eq("the proxy is told one color, and the poll after the off tells it nothing", #told, 1)
T.eq(
  "the Dim color, as warm as the bulb goes",
  C4:ColorXYtoCCT(told[1].LIGHT_COLOR_CURRENT_X, told[1].LIGHT_COLOR_CURRENT_Y),
  2500
)

T.section("The next on, to 60 %")

sent = {}
p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 60, RATE = 0 })
clock.run(3000)
T.check("carries its color to the bulb", sent[1].state and sent[1].has_color_temperature)
local on = h.device.state()
T.check(
  "which comes on in the Dim-To-Warm white for 60 %, not the white it kept",
  on.on and on.color.kelvin > lit.color.kelvin and on.color.kelvin < 5000,
  on.color.kelvin
)

A.sendNow = sendNow
T.eq("no callback raised", clock.errors, {})
restoreConfig()
p:restore()
clock.restore()

T.finish()
