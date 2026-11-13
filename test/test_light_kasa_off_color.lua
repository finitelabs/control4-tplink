-- The TP-Link Light on the Kasa rig, which drops the color a set that turns it off carries, as dev's KL135 did:
-- under Dim-To-Warm an off from 25 % is sent with the Dim color, the bulb stays in the white it was lit in, and the
-- proxy ends showing that white.

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
clock.run(17000)

--- A color coordinate to four places, as the proxy shows it.
--- @param v number|string
--- @return number
local function round(v)
  return math.floor(tonumber(v) * 10000 + 0.5) / 10000
end

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
T.check("the bulb is lit at 25 % in a white between the Dim and On colors",
  lit.on and lit.color.kelvin ~= nil and lit.color.kelvin > 2200 and lit.color.kelvin < 5000, lit.color.kelvin)

p:mark()
p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 750 })
clock.run(20000)
local off = h.device.state()
T.eq("the bulb is off in the white it was lit in", { off.on, off.color.kelvin }, { false, lit.color.kelvin })
local litX, litY = C4:ColorCCTtoXY(lit.color.kelvin)
local told = {}
for _, c in ipairs(p:told("LIGHT_COLOR_CHANGED")) do
  told[#told + 1] = { round(c.LIGHT_COLOR_CURRENT_X), round(c.LIGHT_COLOR_CURRENT_Y) }
end
T.eq("the proxy is told the off's Dim color, then the white the bulb kept", #told, 2)
T.neq("first the Dim color it was sent", told[1], { round(litX), round(litY) })
T.eq("and it ends showing the white the bulb kept", told[#told], { round(litX), round(litY) })

T.eq("no callback raised", clock.errors, {})
restoreConfig()
p:restore()
clock.restore()

T.finish()
