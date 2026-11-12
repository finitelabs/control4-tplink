--- The tplink_light conformance rigs: the driver as it ships, behind fakes of its transports alone. A
--- Kasa bulb on the legacy port fades over the time a command carries; a Tapo bulb over KLAP takes none,
--- and fades on its own only with its own fades on; a light bound to a TP-Link outlet is a relay. Each
--- fake answers a request after ANSWER_MS, and a bulb reports the values it heads to while it fades.

local Rig = require("light_rig")
local F = require("c4_fixtures")
local deferred = require("deferred")

local ROOT = (debug.getinfo(1, "S").source:match("^@(.*)/") or ".") .. "/.."
local DRIVER = ROOT .. "/drivers/tplink_light/driver.lua"
local OUTLET_BINDING = 1
local OUTLET_DEVICE = 9001
local OUTLET_LIGHT_BINDING = 4001
local ANSWER_MS = 50
local IP = "192.0.2.10"
local MAC = "00-00-5E-00-53-01"
local BULB_SERVICE = "smartlife.iot.smartbulb.lightingservice"
-- A Tapo light names no length for a change of level or color, and takes about a second.
local CHANGE_MS = 1000

--- @class TplinkRigFade
--- @field from number The output at the start, 0-1, 0 when dark.
--- @field to number
--- @field start integer
--- @field ms integer

--- One of the light's own fades, as get_on_off_gradually_info names it.
--- @class TplinkRigGradual
--- @field enable boolean
--- @field duration integer|nil Seconds.

--- The light's own fades.
--- @class TplinkRigGradualSet
--- @field on_state TplinkRigGradual
--- @field off_state TplinkRigGradual
--- @field change_state TplinkRigGradual

--- A bulb's values, as both schemas hold them.
--- @class TplinkRigBulb
--- @field on boolean
--- @field brightness integer 1-100.
--- @field hue integer 0-359.
--- @field saturation integer 0-100.
--- @field colorTemp integer Kelvin; 0 while in a color.
--- @field kelvinMin integer
--- @field kelvinMax integer
--- @field fade TplinkRigFade|nil
--- @field gradual TplinkRigGradualSet|nil A SMART light's own fades; nil on a Kasa light.
--- @field reachable boolean

--- How a rig's driver reaches its light.
--- @class TplinkRigKind
--- @field schema "iot"|"smart"|"outlet"
--- @field fades "Driver"|"Light"|nil The Fades property, on a SMART light.
--- @field gradual TplinkRigGradualSet|nil The SMART light's own fades at the start.

--- @param bulb TplinkRigBulb
--- @param now integer
--- @return number
local function output(bulb, now)
	local fade = bulb.fade
	if fade then
		local p = (now - fade.start) / fade.ms
		if p < 1 then
			return fade.from + (fade.to - fade.from) * math.max(0, p)
		end
		bulb.fade = nil
	end
	return bulb.on and bulb.brightness / 100 or 0
end

--- Head the bulb to its values over `ms`, from where its output is.
--- @param bulb TplinkRigBulb
--- @param was number
--- @param ms integer
--- @param now integer
local function head(bulb, was, ms, now)
	local to = bulb.on and bulb.brightness / 100 or 0
	bulb.fade = ms > 0 and was ~= to and { from = was, to = to, start = now, ms = ms } or nil
end

--- @param bulb TplinkRigBulb
--- @param kelvin number
--- @return integer
local function clampKelvin(bulb, kelvin)
	return math.max(bulb.kelvinMin, math.min(bulb.kelvinMax, math.floor(kelvin + 0.5)))
end

--- Another hand's values, or the start's.
--- @param bulb TplinkRigBulb
--- @param state LightValues
local function put(bulb, state)
	if state.on ~= nil then
		bulb.on = state.on
	end
	if state.level ~= nil then
		bulb.brightness = math.max(1, math.min(100, math.floor(state.level * 100 + 0.5)))
	end
	local c = state.color
	if c and c.kelvin then
		bulb.colorTemp = clampKelvin(bulb, c.kelvin)
	elseif c and c.x then
		local h, s = C4:ColorXYtoHSV(c.x, c.y)
		bulb.hue, bulb.saturation, bulb.colorTemp = math.floor(h + 0.5) % 360, math.floor(s + 0.5), 0
	end
	bulb.fade = nil
end

--- The light's values, as a Kasa bulb's light_state names them.
--- @param bulb TplinkRigBulb
--- @return table<string, integer|string>
local function iotValues(bulb)
	return {
		mode = "normal",
		brightness = bulb.brightness,
		hue = bulb.hue,
		saturation = bulb.saturation,
		color_temp = bulb.colorTemp,
	}
end

--- A Kasa bulb's answer to a request over the legacy port.
--- @param bulb TplinkRigBulb
--- @param payload table
--- @param now integer
--- @return table
local function iotAnswer(bulb, payload, now)
	if Select(payload, "system", "get_sysinfo") then
		local state = { on_off = bulb.on and 1 or 0 }
		if bulb.on then
			for k, v in pairs(iotValues(bulb)) do
				state[k] = v
			end
		else
			state.dft_on_state = iotValues(bulb)
		end
		return {
			system = {
				get_sysinfo = {
					err_code = 0,
					model = "KL130(US)",
					mic_mac = MAC:gsub("-", ""),
					is_dimmable = 1,
					is_color = 1,
					is_variable_color_temp = 1,
					light_state = state,
				},
			},
		}
	end
	local params = Select(payload, BULB_SERVICE, "transition_light_state")
	if type(params) ~= "table" then
		return {}
	end
	local was = output(bulb, now)
	if params.on_off ~= nil then
		bulb.on = params.on_off == 1
	end
	if params.brightness ~= nil then
		bulb.brightness = params.brightness
	end
	if params.color_temp ~= nil and params.color_temp > 0 then
		bulb.colorTemp = clampKelvin(bulb, params.color_temp)
	elseif params.hue ~= nil then
		bulb.hue, bulb.saturation, bulb.colorTemp = params.hue, params.saturation, 0
	end
	head(bulb, was, params.transition_period or 0, now)
	local answer = { err_code = 0, on_off = bulb.on and 1 or 0 }
	for k, v in pairs(iotValues(bulb)) do
		answer[k] = v
	end
	return { [BULB_SERVICE] = { transition_light_state = answer } }
end

--- How long a SMART light takes to a change, by its own fades.
--- @param bulb TplinkRigBulb
--- @param wasOn boolean
--- @return integer
local function ownMs(bulb, wasOn)
	local gradual = bulb.gradual
	if not gradual then
		return 0
	end
	local fade
	if bulb.on and not wasOn then
		fade = gradual.on_state
	elseif wasOn and not bulb.on then
		fade = gradual.off_state
	elseif bulb.on then
		return gradual.change_state.enable and CHANGE_MS or 0
	end
	return fade and fade.enable and (fade.duration or 0) * 1000 or 0
end

--- A Tapo light's answer to a SMART request.
--- @param bulb TplinkRigBulb
--- @param payload table
--- @param now integer
--- @return table
local function smartAnswer(bulb, payload, now)
	local method, params = payload.method, payload.params or {}
	if method == "get_device_info" then
		return {
			error_code = 0,
			result = {
				device_on = bulb.on,
				brightness = bulb.brightness,
				hue = bulb.hue,
				saturation = bulb.saturation,
				color_temp = bulb.colorTemp,
				color_temp_range = { bulb.kelvinMin, bulb.kelvinMax },
				mac = MAC,
				model = "L530",
			},
		}
	elseif method == "set_device_info" then
		local was, wasOn = output(bulb, now), bulb.on
		if params.device_on ~= nil then
			bulb.on = params.device_on
		end
		if params.brightness ~= nil then
			bulb.brightness = params.brightness
		end
		if params.color_temp ~= nil and params.color_temp > 0 then
			bulb.colorTemp = clampKelvin(bulb, params.color_temp)
		elseif params.hue ~= nil then
			bulb.hue, bulb.saturation, bulb.colorTemp = params.hue, params.saturation, 0
		end
		head(bulb, was, ownMs(bulb, wasOn), now)
		return { error_code = 0 }
	elseif method == "get_on_off_gradually_info" and bulb.gradual then
		local info = {}
		for name, fade in pairs(bulb.gradual) do
			info[name] = { enable = fade.enable, duration = fade.duration }
		end
		return { error_code = 0, result = info }
	elseif method == "set_on_off_gradually_info" and bulb.gradual then
		for name, fade in pairs(params) do
			if bulb.gradual[name] then
				bulb.gradual[name] = { enable = fade.enable, duration = fade.duration or bulb.gradual[name].duration }
			end
		end
		return { error_code = 0 }
	end
	return { error_code = -1 }
end

--- A fake transport, routed to the bulb a rig loaded last.
--- @class TplinkRigTransport
--- @field answer fun(payload: table): table|nil nil when the light does not answer.
--- @field at fun(ms: integer, fn: fun())
local Transport = {}
Transport.__index = Transport

function Transport:configure() end

function Transport:reset() end

function Transport:connect()
	local d = deferred.new()
	local route = self.route
	route.at(ANSWER_MS, function()
		if route.reachable() then
			d:resolve({})
		else
			d:reject({ error = "no response" })
		end
	end)
	return d
end

function Transport:request(payload)
	local d = deferred.new()
	local route = self.route
	local answer = route.answer and route.answer(payload)
	route.at(ANSWER_MS, function()
		if answer ~= nil then
			d:resolve(answer)
		else
			d:reject({ error = "no response" })
		end
	end)
	return d
end

--- Where each transport the driver makes sends its requests: the IOT light on the legacy port, the
--- SMART light over KLAP and TPAP, as the rig sets them.
--- @class TplinkRigRoutes
--- @field legacy table
--- @field klap table

--- Stand in for the three transports, each made routed to `routes`. The adapter and the probe take
--- them at their load, so both load afresh.
--- @param routes TplinkRigRoutes
local function transports(routes)
	local function maker(route)
		return {
			new = function()
				return setmetatable({ route = route }, Transport)
			end,
		}
	end
	package.loaded["tplink.klap"] = maker(routes.klap)
	package.loaded["tplink.legacy"] = maker(routes.legacy)
	local tpap = maker(routes.klap)
	tpap.discover = function()
		return deferred.new():reject({ error = "no answer to TPAP discover" })
	end
	tpap.supports = function()
		return false
	end
	package.loaded["tplink.tpap"] = tpap
	package.loaded["tplink.light_adapter"] = nil
	package.loaded["tplink.light_probe"] = nil
end

--- A route nothing answers on.
--- @param h LightRigHarness
--- @return table
local function nowhere(h)
	return {
		at = h.clock.at,
		reachable = function()
			return false
		end,
	}
end

--- A bulb reached directly.
--- @param h LightRigHarness
--- @param kind TplinkRigKind
--- @param state LightValues|nil
--- @return LightRigDevice
local function bulbDevice(h, kind, state)
	local smart = kind.schema == "smart"
	--- @type TplinkRigBulb
	local bulb = {
		on = false,
		brightness = 100,
		hue = 0,
		saturation = 100,
		colorTemp = 2700,
		kelvinMin = 2500,
		kelvinMax = smart and 6500 or 9000,
		reachable = true,
	}
	if smart and kind.gradual then
		bulb.gradual = {}
		for name, fade in pairs(kind.gradual) do
			bulb.gradual[name] = { enable = fade.enable, duration = fade.duration }
		end
	end
	if state then
		put(bulb, state)
	end
	local answer = smart and smartAnswer or iotAnswer
	local route = {
		at = h.clock.at,
		reachable = function()
			return bulb.reachable
		end,
		answer = function(payload)
			if bulb.reachable then
				return answer(bulb, payload, h.clock.now())
			end
		end,
	}
	local none = nowhere(h)
	transports(smart and { klap = route, legacy = none } or { klap = none, legacy = route })

	local fake = {}

	function fake.state()
		local out = output(bulb, h.clock.now())
		local color
		if bulb.colorTemp > 0 then
			color = { kelvin = bulb.colorTemp }
		else
			local x, y = C4:ColorHSVtoXY(bulb.hue, bulb.saturation, 100)
			color = { x = x, y = y }
		end
		if bulb.fade then
			return { on = out > 0, level = out, color = color }
		end
		return { on = bulb.on, level = bulb.brightness / 100, color = color }
	end

	-- The light pushes nothing: a poll reads it whole, so no change is quiet.
	function fake.set(values, _quiet)
		put(bulb, values)
	end

	function fake.drop()
		bulb.reachable = false
		bulb.fade = nil
	end

	function fake.back()
		bulb.reachable = true
	end

	return fake
end

--- A light bound to a TP-Link outlet: its relay, as the outlet driver tells it.
--- @param h LightRigHarness
--- @param state LightValues|nil
--- @return LightRigDevice
local function outletDevice(h, state)
	local relay = state ~= nil and state.on == true
	local online = true
	transports({ klap = nowhere(h), legacy = nowhere(h) })
	C4:Bind(OUTLET_DEVICE, OUTLET_LIGHT_BINDING, 0, OUTLET_BINDING, "TPLINK_LIGHT")

	-- The outlet driver's UPDATE_STATE.
	local function push()
		if not online then
			return
		end
		ReceivedFromProxy(OUTLET_BINDING, "UPDATE_STATE", {
			entity = SerializeSafe({ supported_color_modes = { 1 } }),
			state = SerializeSafe({ state = relay }),
		})
	end

	local prior = C4.SendToProxy
	C4.SendToProxy = function(self, id, cmd, params, ...)
		if tonumber(id) ~= OUTLET_BINDING then
			return prior(self, id, cmd, params, ...)
		end
		if cmd == "REFRESH_STATE" and online then
			h.clock.at(ANSWER_MS, push)
		elseif cmd == "ENTITY_COMMAND" and online then
			local opts = DeserializeSafe(Select(params, "body"))
			if type(opts) == "table" and opts.has_state then
				relay = opts.state and true or false
				h.clock.at(ANSWER_MS, push)
			end
		end
	end

	local fake = {}

	function fake.state()
		return { on = relay, level = relay and 1 or 0 }
	end

	function fake.set(values, _quiet)
		if values.on ~= nil then
			relay = values.on
		end
		h.clock.at(ANSWER_MS, push)
	end

	function fake.drop()
		online = false
		ReceivedFromProxy(OUTLET_BINDING, "UPDATE_DISCONNECT", {})
	end

	function fake.back()
		online = true
		h.clock.at(ANSWER_MS, push)
	end

	return fake
end

--- A rig for one way of reaching a light.
--- @param name string
--- @param kind TplinkRigKind
--- @return LightRig
local function rig(name, kind)
	local r = { name = name }
	function r.load(h, state)
		local fake
		if kind.schema == "outlet" then
			fake = outletDevice(h, state)
		else
			C4:Unbind(0, OUTLET_BINDING)
			fake = bulbDevice(h, kind, state)
			Properties["IP Address"] = IP
			Properties["Protocol"] = "Auto"
			local smart = kind.schema == "smart"
			Properties["TP-Link Username"] = smart and "rig@example.com" or ""
			Properties["TP-Link Password"] = smart and "rig-password" or ""
			Properties["Fades"] = kind.fades or "Driver"
		end
		F.dofileBuild(DRIVER, "oss")
		OnDriverInit()
		ShimLateInit()
		return fake
	end
	return r
end

return {
	version = Rig.VERSION,
	rigs = {
		tplink_light = {
			rig("Kasa bulb on the legacy port", { schema = "iot" }),
			rig("Tapo bulb, the driver fades it", {
				schema = "smart",
				fades = "Driver",
				gradual = {
					on_state = { enable = false, duration = 1 },
					off_state = { enable = false, duration = 1 },
					change_state = { enable = false },
				},
			}),
			rig("Tapo bulb, it fades on its own", {
				schema = "smart",
				fades = "Light",
				gradual = {
					on_state = { enable = true, duration = 2 },
					off_state = { enable = false, duration = 1 },
					change_state = { enable = true },
				},
			}),
			rig("light bound to an outlet", { schema = "outlet" }),
		},
	},
}
