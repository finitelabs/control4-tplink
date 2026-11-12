-- The TP-Link Light on the Kasa rig, whose every request takes the controller 2 ms as dev's KL135 measured: an on
-- to 100 over 0.3 s, then an off over 0.3 s 1.2 s later, is told falling from 100, and the proxy keeps 100 as
-- Previous On.

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

--- Each LIGHT_BRIGHTNESS_CHANGING since the mark, as its CURRENT.
--- @return integer[]
local function changing()
  local out = {}
  for _, params in ipairs(p:told("LIGHT_BRIGHTNESS_CHANGING")) do
    out[#out + 1] = tonumber(params.LIGHT_BRIGHTNESS_CURRENT)
  end
  return out
end

T.section("An off over 0.3 s, 1.2 s after an on to 100 over 0.3 s")

p:mark()
p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300 })
clock.run(1200)
T.eq("the on is told rising from the lowest level", changing(), { 1 })

p:mark()
p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 300 })
clock.run(3000)
T.eq("the off is told falling from 100", changing(), { 100 })
T.eq("the proxy keeps 100 as Previous On", p.previousOn, 100)

T.section("The same off over 4 s")

p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 100, RATE = 300 })
clock.run(1200)
p:mark()
p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 0, RATE = 4000 })
clock.run(6000)
T.eq("the off is told falling from 100", changing(), { 100 })
T.eq("the proxy keeps 100 as Previous On", p.previousOn, 100)

T.eq("no callback raised", clock.errors, {})
restoreConfig()
p:restore()
clock.restore()

T.finish()
