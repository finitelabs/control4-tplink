--- An update from v20261110: the light library's driver loads over the store and proxy state v20261110 left
--- (test/light_upgrade_v20261110.lua), comes up as the light was, and each saved setting works as it did.
--- The probes run in the order v20261110 saw them, each from where the last left the light.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_light_upgrade.lua

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local D = require("light_drivers")
local Caps = require("lib.light.caps")
local Old = require("light_upgrade_v20261110")

-- The rig v20261110 was captured on.
local rig = require("light_rigs").rigs.tplink_light[2]
rig.folder = "tplink_light"

local WAIT = 17000

--- What one probe saw.
--- @class TplinkUpgradeProbe
--- @field name string
--- @field on boolean
--- @field level integer|nil The device's level, percent.
--- @field shown integer|nil The proxy's level.
--- @field kelvin integer|nil
--- @field x integer|nil Thousandths.
--- @field y integer|nil
--- @field rates integer[] The rates LIGHT_BRIGHTNESS_CHANGING told.
--- @field leds string[] What the links and the proxy were told of the buttons.

--- @param h LightRigHarness
--- @param name string
--- @param fn fun()
--- @return TplinkUpgradeProbe
local function probe(h, name, fn)
	local p = h.proxy
	p:mark()
	fn()
	h.clock.run(WAIT)
	local s = h.device.state()
	local rates, leds = {}, {}
	for _, n in ipairs(p.notes) do
		if n.cmd == "LIGHT_BRIGHTNESS_CHANGING" then
			rates[#rates + 1] = tonumber(n.params.RATE)
		elseif n.cmd == "BUTTON_COLORS" or n.cmd == "MATCH_LED_STATE" then
			leds[#leds + 1] = string.format(
				"%s:%s:%s/%s",
				n.cmd,
				tostring(n.binding),
				tostring(n.params.ON_COLOR or n.params.STATE),
				tostring(n.params.OFF_COLOR)
			)
		end
	end
	return {
		name = name,
		on = s.on,
		level = s.level and math.floor(s.level * 100 + 0.5),
		shown = p.level,
		kelvin = s.color and s.color.kelvin,
		x = s.color and s.color.x and math.floor(s.color.x * 1000 + 0.5),
		y = s.color and s.color.y and math.floor(s.color.y * 1000 + 0.5),
		rates = rates,
		leds = leds,
	}
end

--- The probes, as v20261110 ran them.
--- @param h LightRigHarness
--- @return TplinkUpgradeProbe[]
local function probes(h)
	local p = h.proxy
	return {
		probe(h, "ON: the on mode's preset, on the Min and Max line, in the held color", function()
			p:send("ON")
		end),
		probe(h, "SET_LEVEL 100: Max On", function()
			p:send("SET_LEVEL", { LEVEL = 100 })
		end),
		probe(h, "SET_LEVEL 1: Min On", function()
			p:send("SET_LEVEL", { LEVEL = 1 })
		end),
		probe(h, "OFF", function()
			p:send("OFF")
		end),
		probe(h, "a Top click from off: the click rate up", function()
			p:send("BUTTON_ACTION", { BUTTON_ID = 0, ACTION = 2 })
		end),
		probe(h, "a Bottom click: the click rate down", function()
			p:send("BUTTON_ACTION", { BUTTON_ID = 1, ACTION = 2 })
		end),
		probe(h, "REQUEST_BUTTON_COLORS: the Top's saved colors", function()
			p:send("REQUEST_BUTTON_COLORS")
		end),
		probe(h, "ACTIVATE_SCENE 7: the saved scene runs to its last step", function()
			p:send("ACTIVATE_SCENE", { SCENE_ID = 7 })
		end),
		probe(h, "RAMP_TO_LEVEL 20 with no time: the default rate", function()
			p:send("RAMP_TO_LEVEL", { LEVEL = 20 })
		end),
	}
end

for key, row in pairs(Old.persist) do
	C4:PersistSetValue(key, row)
end
ShimPersistLand()
local clock = F.virtualClock()
local proxy = P.install(clock, { variables = Old.variables, capabilities = Old.held })
local xml = D.xml(D.root(), rig.folder) or ""
D.seedProperties(xml)
local restoreConfig = D.answerConfig(xml)
--- @type LightRigHarness
local h = { clock = clock, proxy = proxy, lo = 1, hi = 100 }
h.device = rig.load(h, Old.device)
clock.run(WAIT)

T.section("over v20261110's store and proxy, the light comes up online as it was left")
T.eq("online", proxy.online, true)
-- With no light_rate_caps stored, the library takes the proxy to hold driver.xml's static capabilities.
-- What v20261110 told is that set, so nothing needs telling.
local light = h.light or require("lib.light").made[#require("lib.light").made]
local held = {}
for key, value in pairs(Caps.dynamic(light.device, light.profile)) do
	if proxy.held[key] ~= nil then
		held[key] = type(value) == "boolean" and (value and "True" or "False") or tostring(value)
	end
end
local shown = {}
for key in pairs(held) do
	shown[key] = proxy.held[key]
end
T.eq("the proxy holds the capabilities the light declares", shown, held)
T.eq("no Brightness Changed: the light is off, as the proxy shows", proxy:count("LIGHT_BRIGHTNESS_CHANGED"), 0)
T.eq("no Color Changed: the proxy shows the color it holds", proxy:count("LIGHT_COLOR_CHANGED"), 0)
T.eq("the light is left off", h.device.state().on, false)
T.eq("no callback raised", clock.errors, {})

T.section("each setting v20261110 saved works as it did")
local seen = probes(h)
for i, want in ipairs(Old.probes) do
	local got = seen[i]
	T.eq(want.name, {
		on = got.on,
		level = got.level,
		shown = got.shown,
		kelvin = got.kelvin,
		x = got.x,
		y = got.y,
		rates = got.rates,
		leds = got.leds,
	}, {
		on = want.on,
		level = want.level,
		shown = want.shown,
		kelvin = want.kelvin,
		x = want.x,
		y = want.y,
		rates = want.rates,
		leds = want.leds,
	})
end
T.eq("no callback raised", clock.errors, {})

restoreConfig()
proxy:restore()
clock.restore()
T.finish()
