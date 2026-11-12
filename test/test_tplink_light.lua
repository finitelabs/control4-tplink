--- The TP-Link light on the light library, over the rigs of test/light_rigs.lua: a color another hand sets
--- while the light is off shows, and the next On keeps it; and a level another hand sets after a walk, at
--- a level the walk passed, shows.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_tplink_light.lua

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local P = require("light_proxy_fake")
local D = require("light_drivers")

local rigs = require("light_rigs").rigs.tplink_light
local WAIT = 17000

--- Load a rig's driver afresh, settled online.
--- @param rig LightRig
--- @return LightRigHarness
local function fresh(rig)
	rig.folder = "tplink_light"
	local clock = F.virtualClock()
	local proxy = P.install(clock, {})
	local xml = D.xml(D.root(), rig.folder) or ""
	D.seedProperties(xml)
	local restoreConfig = D.answerConfig(xml)
	--- @type LightRigHarness
	local h = { clock = clock, proxy = proxy, lo = 1, hi = 100 }
	function h.done()
		restoreConfig()
		proxy:restore()
		clock.restore()
	end
	h.device = rig.load(h, nil)
	clock.run(WAIT)
	return h
end

--- @param a {x: number, y: number}|nil
--- @param b {x: number, y: number}|nil
--- @return boolean
local function sameXY(a, b)
	return a ~= nil and b ~= nil and math.abs(a.x - b.x) <= 0.01 and math.abs(a.y - b.y) <= 0.01
end

--- @param color LightColor|nil
--- @return {x: number, y: number}|nil
local function xyOf(color)
	if type(color) ~= "table" then
		return nil
	end
	if color.x then
		return { x = color.x, y = color.y }
	end
	local x, y = C4:ColorCCTtoXY(color.kelvin)
	return { x = x, y = y }
end

local BLUE = { x = 0.167, y = 0.04 }

for _, rig in ipairs({ rigs[1], rigs[2], rigs[3] }) do
	T.section(rig.name .. ": a color set in the TP-Link app while the light is off shows, and the next On keeps it")
	do
		local h = fresh(rig)
		local p = h.proxy
		p:send("UPDATE_COLOR_ON_MODE", {
			COLOR_PRESET_ID = 0,
			COLOR_PRESET_ORIGIN = 0,
			COLOR_FADE_PRESET_ID = 0,
			COLOR_FADE_PRESET_ORIGIN = 0,
		})
		p:send("SET_LEVEL", { LEVEL = 60 })
		h.clock.run(WAIT)
		p:send(
			"SET_COLOR_TARGET",
			{ LIGHT_COLOR_TARGET_X = 0.6, LIGHT_COLOR_TARGET_Y = 0.3, LIGHT_COLOR_TARGET_MODE = 0 }
		)
		h.clock.run(WAIT)
		p:send("OFF")
		h.clock.run(WAIT)
		p:mark()
		h.device.set({ on = false, color = BLUE })
		-- The blue as the light holds it, in its own hue and saturation.
		local app = xyOf(h.device.state().color)
		h.clock.run(WAIT)
		T.check(
			"the proxy shows the app's color",
			sameXY({ x = tonumber(p.color.x), y = tonumber(p.color.y) }, app),
			T.show(p.color)
		)
		T.eq("and the light stays off", { h.device.state().on, p.level }, { false, 0 })
		p:send("ON")
		h.clock.run(WAIT)
		local color = xyOf(h.device.state().color)
		T.check("the next On comes on in the app's color", sameXY(color, app), T.show(color))
		T.check(
			"as the proxy shows",
			sameXY({ x = tonumber(p.color.x), y = tonumber(p.color.y) }, app),
			T.show(p.color)
		)
		T.eq("no callback raised", h.clock.errors, {})
		h.done()
	end
end

T.section("a walk: another hand's level after it, at a level the walk passed, shows")
do
	local h = fresh(rigs[2])
	local p = h.proxy
	p:send("SET_LEVEL", { LEVEL = 20 })
	h.clock.run(WAIT)
	p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
	h.clock.run(3000)
	T.eq("the walk ends at 80", math.floor(h.device.state().level * 100 + 0.5), 80)
	-- Inside the walk's window, and well after it.
	for _, after in ipairs({ 200, 2500, WAIT }) do
		h.device.set({ on = true, level = 0.8 })
		h.clock.run(WAIT)
		p:send("SET_LEVEL", { LEVEL = 80 })
		p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 20, RATE = 0 })
		h.clock.run(WAIT)
		p:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 })
		h.clock.run(3000 + after)
		h.device.set({ on = true, level = 0.5 })
		h.clock.run(WAIT)
		T.eq(string.format("50, set %d ms after the walk, shows", after), p.level, 50)
	end
	T.eq("no callback raised", h.clock.errors, {})
	h.done()
end

T.finish()
