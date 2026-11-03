--- Finding a TP-Link device on the controller's network by its MAC address,
--- and following it when its address changes.
---
--- The controller's server and broadcast calls are stand-ins: a test hands
--- the listener what devices would send back.
---
--- Run from the driver root:
---   make test
--- or:
---   ./test/run_test.sh test_discovery.lua

local T = require("testlib")

require("c4_shim")

local cipher = require("tplink.kasa-cipher")
local persist = require("lib.persist")

--- Listeners open, by port; ports refused; every broadcast; ports closed.
local servers, refused, broadcasts, closed = {}, {}, {}, {}

function C4:CreateServer(port, _, udp, identifier)
  if refused[port] then
    return false, "address in use"
  end
  servers[port] = { udp = udp, identifier = identifier }
  return true
end

function C4:DestroyServer(port)
  servers[port] = nil
  closed[#closed + 1] = port
end

function C4:SendBroadcast(payload, port, sourcePort)
  broadcasts[#broadcasts + 1] = { payload = payload, port = port, from = sourcePort }
end

local osVersion = "4.3.0.766029-res"
function C4:GetVersionInfo()
  return { version = osVersion }
end

function C4:UpdateProperty(name, value)
  Properties[name] = value
end

Properties = { ["Driver Status"] = "Disconnected: no answer" }

--- Another server of the driver's own, which must still get its data.
local otherData = {}
function OnServerDataIn(_, strData, _, _, identifier)
  otherData[#otherData + 1] = { strData, identifier }
end

local Discovery = require("tplink.discovery")

--- The listener the shim's device id (12345) is given.
local PORT = 47300 + 12345 % 500

local function reset()
  servers, refused, broadcasts, closed = {}, {}, {}, {}
  osVersion = "4.3.0.766029-res"
  Discovery.stop()
  closed = {}
end

--- What a device sends back to the KLAP query: a 16-byte header, then JSON.
local function klapAnswer(mac)
  local json = JSON:encode({ error_code = 0, result = { device_model = "ZX100(US)", mac = mac } })
  return string.rep("\0", 16) .. json
end

--- What a device sends back to the legacy query.
local function legacyAnswer(sysinfo)
  return cipher.scramble(JSON:encode({ system = { get_sysinfo = sysinfo } }))
end

--- A device answers the open listener.
local function answer(data, address, fromPort)
  local _, server = next(servers)
  OnServerDataIn(7, data, address, tostring(fromPort), server and server.identifier)
end

--- The address a search resolved with, or "pending".
local function outcome(d)
  local got = "pending"
  d:next(function(address)
    got = address
  end)
  return got
end

T.section("a MAC address is kept in one spelling")
do
  T.eq("dashes", Discovery.normalizeMac("02-1a-2b-3c-4d-5e"), "02:1A:2B:3C:4D:5E")
  T.eq("colons", Discovery.normalizeMac("02:1A:2B:3C:4D:5E"), "02:1A:2B:3C:4D:5E")
  T.eq("none, as bulbs send it", Discovery.normalizeMac("021A2B3C4D5E"), "02:1A:2B:3C:4D:5E")
  T.eq("too short", Discovery.normalizeMac("02:1A:2B"), nil)
  T.eq("not a string", Discovery.normalizeMac(nil), nil)
end

T.section("the MAC is read from either answer")
do
  T.eq("the KLAP answer", Discovery.parse(klapAnswer("02-1A-2B-3C-4D-5E"), "20002"), "02:1A:2B:3C:4D:5E")
  T.eq("the legacy answer", Discovery.parse(legacyAnswer({ mac = "02:1A:2B:3C:4D:5F" }), 9999), "02:1A:2B:3C:4D:5F")
  T.eq("a bulb's legacy answer", Discovery.parse(legacyAnswer({ mic_mac = "021A2B3C4D60" }), 9999), "02:1A:2B:3C:4D:60")
  T.eq("a cut-short KLAP answer", Discovery.parse(string.rep("\0", 20), 20002), nil)
  T.eq("noise on the legacy port", Discovery.parse("noise", 9999), nil)
  T.eq("another port", Discovery.parse(klapAnswer("02-1A-2B-3C-4D-5E"), 20004), nil)
end

T.section("a search needs OS 4.0, where a broadcast can come from the listener's port")
do
  T.truthy("4.3", Discovery.supported())
  osVersion = "3.4.3.123456-res"
  T.falsy("3.4", Discovery.supported())
  T.eq("and a search there finds nothing", outcome(Discovery.find("02:1A:2B:3C:4D:5E")), nil)
  T.eq("without opening a listener", next(servers), nil)
  reset()
end

T.section("a search broadcasts both queries from its listener and ends at the device's answer")
do
  local d = Discovery.find("02-1a-2b-3c-4d-5e")
  T.eq("a UDP listener on this driver's port", servers[PORT], { udp = true, identifier = "tplink-discovery" })
  T.eq("both queries from it", { broadcasts[1].port, broadcasts[1].from, broadcasts[2].port, broadcasts[2].from }, {
    20002,
    PORT,
    9999,
    PORT,
  })
  T.eq(
    "the legacy query asks for the device's info",
    cipher.unscramble(broadcasts[2].payload),
    '{"system":{"get_sysinfo":{}}}'
  )
  T.eq("the same search while one runs", Discovery.find("02:1A:2B:3C:4D:5E"), d)
  answer(klapAnswer("02-1A-2B-3C-4D-99"), "192.0.2.40", 20002)
  T.eq("another device's answer is not the one", outcome(d), "pending")
  answer(legacyAnswer({ mac = "02:1A:2B:3C:4D:5E" }), "192.0.2.41", 9999)
  T.eq("the device's answer gives its address", outcome(d), "192.0.2.41")
  T.eq("and closes the listener", closed, { PORT })
  T.eq("other servers' data still reaches the driver", otherData, {})
  OnServerDataIn(3, "hello", "192.0.2.5", "8080", "own-server")
  T.eq("the driver's own server", otherData, { { "hello", "own-server" } })
  reset()
end

T.section("a search no device answers ends with nothing, after three sends of each query")
do
  local d = Discovery.find("02:1A:2B:3C:4D:5E")
  for _ = 1, 4 do
    ShimFireTimers()
  end
  T.eq("nothing found", outcome(d), nil)
  T.eq("each query three times", #broadcasts, 6)
  T.eq("the listener closed", closed, { PORT })
  reset()
end

T.section("a port another server holds is passed over")
do
  refused[PORT] = true
  Discovery.find("02:1A:2B:3C:4D:5E")
  T.truthy("the next port", servers[PORT + 1])
  reset()
end

T.section("the follower learns its device's MAC and follows it to a new address")
do
  local moved, looking = {}, {}
  local follower = Discovery.Follower:new(function(address)
    moved[#moved + 1] = address
  end, function(on)
    looking[#looking + 1] = on
  end)
  follower:forget()
  follower:lost()
  T.eq("with no MAC learned, a lost device is not searched for", next(servers), nil)

  T.truthy("the first device seen is taken", follower:accepts("02-1A-2B-3C-4D-5E"))
  T.eq("and its MAC kept", persist:get("discovery_mac"), "02:1A:2B:3C:4D:5E")
  T.truthy("it again, in another spelling", follower:accepts("021a2b3c4d5e"))
  T.falsy("another device", follower:accepts("02:1A:2B:3C:4D:99"))
  T.truthy("an answer with no MAC", follower:accepts(nil))

  follower:lost()
  T.truthy("a lost device is searched for at once", servers[PORT])
  T.eq("and the driver is told it is looking", looking, { true })
  follower:lost()
  T.eq("once", #broadcasts, 2)
  answer(klapAnswer("02-1A-2B-3C-4D-5E"), "192.0.2.77", 20002)
  T.eq("the driver is told where it is", moved, { "192.0.2.77" })
  T.eq("and that the search is over", looking, { true, false })
  T.eq("Driver Status is the driver's own", Properties["Driver Status"], "Disconnected: no answer")
  reset()
end

T.section("a device not found is searched for again later, until it answers")
do
  local moved = {}
  local follower = Discovery.Follower:new(function(address)
    moved[#moved + 1] = address
  end)
  follower:forget()
  follower:accepts("02:1A:2B:3C:4D:5E")
  follower:lost()
  for _ = 1, 4 do
    ShimFireTimers()
  end
  T.eq("no answer to the first", #broadcasts, 6)
  T.eq("the listener closed", next(servers), nil)
  ShimFireTimers()
  T.truthy("a second search", servers[PORT])
  answer(klapAnswer("02-1A-2B-3C-4D-5E"), "192.0.2.78", 20002)
  T.eq("finds it", moved, { "192.0.2.78" })
  follower:found()
  reset()
end

T.section("a device that answers again stops the search, and a hand edit forgets the MAC")
do
  local follower = Discovery.Follower:new(function() end)
  follower:forget()
  follower:accepts("02:1A:2B:3C:4D:5E")
  follower:lost()
  follower:found()
  T.eq("the listener closed", next(servers), nil)
  ShimFireTimers()
  T.eq("and no search scheduled", next(servers), nil)
  follower:forget()
  T.eq("forgotten", follower:mac(), nil)
  T.truthy("so whichever device answers next is followed", follower:accepts("02:1A:2B:3C:4D:99"))
  T.eq("from then on", follower:mac(), "02:1A:2B:3C:4D:99")
  follower:forget()
  reset()
end

T.section("a stop ends the search under way and leaves none due, as at a driver's destroy")
do
  local looking = {}
  local follower = Discovery.Follower:new(function() end, function(on)
    looking[#looking + 1] = on
  end)
  follower:forget()
  follower:accepts("02:1A:2B:3C:4D:5E")
  follower:lost()
  follower:stop()
  T.eq("the listener closed", next(servers), nil)
  T.eq("the driver is told the search is over", looking, { true, false })
  ShimFireTimers()
  T.eq("and no search follows", next(servers), nil)
  follower:forget()
  reset()
end

T.finish()
