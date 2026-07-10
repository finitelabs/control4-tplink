# tplink_light driver plan

## Goal

One light driver, two backends, replacing chowmain_tplink_v2_light (x3) and
chowmain_tplink_klap_device/klap_light (L930-5 "Rack Lights", Equipment
Closet, 192.168.2.24, device 2324/2325 today, light proxy 2326).

## Design (agreed 2026-07-10)

1. `tplink_outlet` gains a dynamic per-output light binding
   (namespace "light", key "output_n", class `TPLINK_LIGHT`, CONTROL
   provider, "Output N Light"). The outlet driver handles ON/OFF/TOGGLE
   from the bound light driver and notifies it with `STATE_CHANGED`
   (`STATE = "0"/"1"`) on relay changes, plus answers `REQUEST_STATE`.
2. New `drivers/tplink_light`: light_v2 combo driver ported from
   control4-esphome `drivers/esphome_light/driver.lua` (2454 lines), which
   supports all lighting features conditionally.
   - Backend seam: donor receives entity/state pushes and sends commands
     over its hub PROXY binding 5002. Replace with a `backend` interface:
     `setLight(params)`, `isConnected()`, plus state callbacks into the
     proxy layer.
   - Backend A "outlet mode": control consumer binding 1 (class
     `TPLINK_LIGHT`) bound to a tplink_outlet output. On/off only
     (no dimming); capabilities collapse to switch.
   - Backend B "direct mode": IP + TP-Link credentials properties, SMART
     schema over the existing src/lib/klap.lua transport (payload
     `{method="get_device_info"}` etc.; transport is schema-agnostic).
     L930-5 device_info fields: device_on, brightness (1-100), hue (0-360),
     saturation (0-100), color_temp (K, 0 when in color mode),
     lighting_effect. set_device_info to control.
   - Mode selection: bound to outlet binding wins; otherwise IP configured
     = direct mode. Hide network properties in outlet mode (values/attribs
     pattern).
3. Same repo conventions: values/bindings classes, hidden properties shown
   on connect, mqtt-style docs (no em dashes, no AI-speak), oss +
   drivercentral builds.

## Donor notes (fill in while porting)

- Capabilities XML: copy esphome_light capabilities block verbatim
  (dimmer, supports_target, color, CCT 2000-6500, click/hold rates).
- Button link connections 300/301/302 (On/Toggle/Off) copy as-is.
- Proxy: light_v2 proxybindingid 5001.
- `ESPHOME_BINDING = 5002` is the donor's hub binding; ours is binding 1
  (TPLINK_LIGHT consumer) + klap transport.

## Migration map (after driver works)

- Astronaut Lamp: outlet 1872 DELETEME + v2_light 1194 -> tplink_outlet
  instance (Office plug, 192.168.2.9, "Astronaut Lamp") + tplink_light in
  outlet mode bound to its Output 1 Light; light proxy 1195 rebinds to the
  new light driver's LIGHT_V2 5001? No: 1195 IS the proxy device fronted by
  1194's 5001 binding. Our tplink_light replaces 1194; proxy device is
  auto-created when adding the light driver. Re-point any UI/scene refs.
- EP40A (2675, offline, seasonal Christmas lights): two light channels
  ("Lawn Christmas Lights" 2088/2089, "Roof Christmas Lights" 2676/2677).
  Needs tplink_outlet + two tplink_light instances in outlet mode.
- Rack Lights L930-5: tplink_light direct mode, then remove 2324/2325.
- Then remove TP-Link agent 1868 and remaining chowmain tplink drivers.

## Rack Lights migration checklist (inventory 2026-07-10)

Old chain: 2324 (klap_device, "L930-5 DELETEME") -> 2325 (klap_light) ->
proxy 2326 ("Rack Lights DELETEME"). New: 2800 (tplink_light, "Rack
Lights") -> proxy 2801 ("Rack Lights").

1. Programming: 8 command actions target proxy 2326 (code_items 1299, 1300,
   1303, 1305, 1306, 1374, 1375, 1377: on/off, "Set the color 6500K",
   "Set the color (0.131192, 0.049698)"). Re-point item_id 2326 -> 2801 via
   the Director SOAP programming API (no DB surgery).
2. Home Connect (device 1388): "Select Lights and Relays" DEVICE_SELECTOR
   includes 2326 (and 1195, the Astronaut Lamp proxy, for that later
   migration). Replace 2326 with 2801 via eval UpdateProperty on 1388.
3. Nightlight Routine (device 2153, routine-nightlight.c4z): savedModes and
   Objects persist references to 2326; reconfigure to 2801.
4. Apple Bridge (2249) / HomeKit (2250): persisted state references 2326;
   verify the new light exports and remove the old one.
5. No events or variable watches on 2324/2325/2326; connections are all
   chowmain-internal.
6. After verification: delete 2324/2325/2326, then the TP-Link agent 1868
   once the remaining chowmain TP-Link drivers are migrated.

## Verification

- Direct mode against L930-5 (192.168.2.24) while chowmain still runs:
  on/off, brightness, color, CCT round trips.
- Outlet mode against a tplink_outlet instance.
