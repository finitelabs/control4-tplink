# <span style="color:#4ACBD6">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## v20261106 - 2026-11-06

### Fixed

- Fixed a scene step that sets only a color turning on a light that is off. The
  color is now kept for the light's next on, as a color command's is.
- Fixed a color sent to a Kasa light that is fading to off turning it back on.
  The light now goes off and keeps the color for its next on.
- Fixed a scene step's color on a light that cannot show it. A dimmer or switch
  no longer turns on for it, and Control4 is no longer told of a color fade the
  light cannot make.
- Fixed a fade from a color to a white. A stop part way now holds the color the
  light has got to, where it sent a color temperature that took the light to its
  warmest white, and a fade on a Tapo light now goes through the colors between
  instead of jumping to white at its start.

## v20261105 - 2026-11-05

### Added

- Added support for Tapo and Kasa devices with Third-Party Compatibility off in
  the Tapo or Kasa app, on Control4 OS 3.4.1 or later. `Protocol` has a new
  `TPAP` choice for them, and `Auto` finds it.
- Added a `Fades` property to the TP-Link Light driver for Tapo lights, which
  ignore the fade time in a command. On `Driver`, the default, the driver makes
  the fades, so ramp rates, stops, held buttons and scene fades work. On
  `Light`, the light uses its own fades from the Tapo app.
- Added On, Off and Toggle keypad button links to each TP-Link Outlet output. A
  keypad button bound to one switches the output, and its LED follows it.
- Added `Output N In Use` and `Output N Idle` events and an `Output N In Use`
  variable to the TP-Link Outlet driver, set from each output's power and two
  levels, `In Use Above (W)` and `Idle Below (W)`. `Hold (s)` sets how long the
  power must stay past a level before the event fires.
- Added address following to the TP-Link Outlet and TP-Link Light drivers: when
  the device gets another address on the controller's network, the driver finds
  it by its MAC address and updates `IP Address` (OS 4.0 and later). A different
  device that answers at the old address is not controlled. The TP-Link Light
  driver shows the light's `MAC Address`.
  <!-- #ifdef DRIVERCENTRAL -->
- Added DriverCentral licensing and automatic updates. After five minutes
  without an active license, the drivers stop reaching their devices and show
  `No active license` in `Driver Status`; a license starts them again at once.
  `Automatic Updates` set on one TP-Link driver applies to all of them.
- Added a `Support Code` property to the TP-Link Outlet and TP-Link Light
  drivers. A code from Finite Labs support opens the driver's Lua tab in
  Composer for an hour; leave it blank otherwise.
- Added a `Cloud Monitoring` property, Enabled by default, and a
  `Diagnostics Snapshot` action to every driver. Cloud Monitoring sends Finite
  Labs an hourly report of the driver's memory use and a report of each error it
  hits; the documentation says what they hold.
  <!-- #endif -->

### Fixed

- Fixed ramps and stops on TP-Link lights. A stop now holds the light where it
  is and lets a color fade finish, a light asked for the level it has just
  reached stops there, a ramped On no longer switches the light on at its old
  level first, a color light with no color temperature no longer restarts a
  moment into a ramp to on, and Stop Scene Ramp and Ramp Scene Up and Down work
  on a light that is already ramping.
- Fixed keypad buttons on TP-Link lights. Top, Bottom and Toggle links and the
  light's own button actions now work, a held Top or Toggle ramps toward full
  until released, and a press during a ramp acts on the level the light has
  reached.
- Fixed Advanced Lighting scenes on TP-Link lights. A command or a stop now
  takes the light out of the scene, a scene that flashes with no delay or ramp
  time no longer hangs the driver, and each step fades from the level and color
  the light is at, including during a ramp. A light that only switches is shown
  on or off as it does.
- Fixed colors on TP-Link lights. Color On Mode set to a color preset now uses
  the preset, Previous turns the light on in the color it faded off in, a color
  set during or right after a ramp is kept, a color the light took while off is
  picked up at once, a color picked for a Tapo light while it is off goes on
  with the next On, and a color change with no ramp time takes the light's
  default ramp rate.
- Fixed Dim-To-Warm on TP-Link lights. A scene step that sets only a level takes
  the Dim-To-Warm color, a color set during a ramp or a scene step stays, and
  the light is no longer shown in two colors at each brightness change.
- Fixed Max On Level and Min On Level having no effect on TP-Link lights. Levels
  1 to 100 now run between the two, as on a Control4 dimmer.
- Fixed a TP-Link light turned on over a ramp time, then stopped or turned off
  part way, setting its Previous On level to 1%.
- Fixed a TP-Link light ending at a level or color other than the last one asked
  for, after quick presses or a dragged slider.
- Fixed TP-Link lights shown at the wrong level or color: for a moment after a
  command, during a ramped On, after a color preset was picked, for a color
  temperature outside the light's range, and at the end of a scene or ramp that
  was taken over or deactivated.
- Fixed the TP-Link Light driver not knowing a light's Color On Mode, on level
  or default ramp rate until one of them was changed in Composer. It now reads
  them from the project when it starts.
- Fixed the TP-Link Light driver storing a light's brightness presets among its
  color presets.
- Fixed TP-Link lights running their Brightness Changed, Color Changed, Level
  Change, Light On or Light Off programming after a controller restart or a
  driver update when nothing had changed. After a controller restart, Control4
  still reports the color variables of a light with color or color temperature
  as changed.
- Fixed a TP-Link light that was offline, or bound to an outlet that was, being
  shown on or off, and running its programming, for a command it never got.
- Fixed a TP-Link Light being shown online in its last state while its outlet
  was offline, after it was unbound from its outlet, or when it found no light
  after a connection property was changed or Reconnect was run.
- Fixed the LEDs of keypad buttons bound to a TP-Link light showing the wrong
  state during a ramped On and after the light went offline.
- Fixed the TP-Link Light driver sending a light its level or color again at the
  end of a fade.
- Fixed a TP-Link device that changed protocol after a firmware update, a
  rollback or a reset staying disconnected. The driver now detects the protocol
  again after three missed polls.
- Fixed the TP-Link Outlet and TP-Link Light drivers showing `Disconnected` for
  a device that was connected, running the outlet's Disconnected programming, or
  connecting over a protocol `Protocol` excludes, after connection properties
  were changed a few seconds apart.
- Fixed `Driver Status` flipping between `Connecting` and the reason a device
  was not found at every poll, and a change of a connection property or a
  Reconnect while the driver was connecting not being tried until the next
  retry.
- Fixed the TP-Link Outlet driver not noticing an output switched at the device
  or in the app, or the device going offline, after a reconnect or a reply it
  could not read, until the driver was reloaded.
- Fixed a TP-Link Outlet output switched during a poll being shown in its old
  state for a moment, which ran its programming, and that of a relay or TP-Link
  Light bound to it, a second time.
- Fixed a relay driver connected to a TP-Link Outlet output running its
  programming when it was connected. A relay driver that asks for the output's
  state is now told it.
- Fixed a relay driver connected to a TP-Link Outlet output reading the output's
  state as unverified after a controller restart, until the output next changed.
- Fixed the TP-Link Outlet and TP-Link Light drivers printing the TP-Link
  account to the Lua output and the log at high log levels. Neither the username
  nor the password is printed at any level now.
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed changing `Automatic Updates` or `Update Channel` on one TP-Link driver
  briefly holding up the others while the change was copied to them.
  <!-- #endif -->

### Changed

- With Dim-To-Warm, a color an Advanced Lighting scene sets on a TP-Link light
  that is on now stays when the light is dimmed or brightened, until it turns
  off, as a color set from Navigator or programming does.
- With Dim-To-Warm, a brightness command for the level a TP-Link light is
  already at now returns a color set from the Tapo app to the Dim-To-Warm color.
- The TP-Link Light driver now shows a light as a dimmer until it connects, then
  turns dimming off for a light that only switches.
- The TP-Link Outlet driver's `Kasa Settings` are now `TP-Link Settings`, and
  its documentation names Tapo plugs and power strips alongside Kasa.
- The TP-Link Outlet driver's `Log Mode` now goes back to `Off` after 3 hours,
  as the TP-Link Light driver's does, and `Log Level` goes back to `3 - Info`
  while logging is off.
- A TP-Link Outlet's `Output N State` properties now read `On` or `Off`. The
  `Output N State` variables still read 1 or 0 for programming.

## v20261002 - 2026-10-02

### Changed

- A device that refuses the KLAP handshake with HTTP 403 (usually because a
  firmware update disabled Third-Party Compatibility in the Tapo/Kasa app, or
  because a newly added device has not picked up the setting) now reports the
  cause and fix in `Driver Status` instead of a raw HTTP error, including
  turning the setting off and back on when it is already on. In `Auto` mode the
  status no longer buries this behind the legacy protocol's failure, and the
  TP-Link Light driver now shows it when a connected light starts refusing.

<!-- #ifndef DRIVERCENTRAL -->

### Fixed

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.

<!-- #endif -->

## v20260714 - 2026-07-14

### Fixed

- TP-Link Outlet: control the individual outputs of multi-outlet legacy plugs
  that report short child ids (such as the EP40A). These devices reject the
  short id in the relay command and require the full device-prefixed child id,
  so per-output on and off now works instead of failing silently.

## v20260713 - 2026-07-13

### Added

- TP-Link Light: direct-mode support for legacy Kasa KL/LB-series bulbs (e.g.
  KL110, KL120, KL125, KL130, KL135) and light strips (KL400/KL420/KL430) via
  the IOT command schema, over the original port 9999 protocol or KLAP firmware
  with either hash generation. Devices on original firmware need no TP-Link
  credentials. Ramp rates forward as device-side transitions, matching the SMART
  path. Any Control4 light command takes over from a lighting effect running on
  a strip.
- TP-Link Light: a Protocol property (Auto/KLAP/Legacy) and a Reconnect action,
  matching the TP-Link Outlet driver. The detected transport and schema show in
  Driver Status as `Connected (SMART)`, `Connected (KLAP)`, or
  `Connected (Legacy)`.
- Verified hardware: a field install confirms the KL130 in direct mode via the
  IOT bulb schema.

### Changed

- TP-Link Light: Tapo-class devices in direct mode now show `Connected (SMART)`
  instead of `Connected (KLAP)`, matching the outlet driver's naming.

## v20260712 - 2026-07-12

### Added

- TP-Link Outlet: SMART command schema support for newer Kasa and Tapo plugs
  (e.g. EP25 hardware v2.6, KP125M, Tapo P-series), auto-detected over KLAP and
  shown as `Connected (SMART)`. TP-Link account credentials are required, and
  SMART devices on very early firmware (EP25 v2.6 firmware 1.0.2 and older) need
  a firmware update through the Kasa app.
- TP-Link Outlet: multi-outlet SMART devices (Tapo power strips, EP40M) are
  controlled through their child outlets, including per-outlet energy readings
  where the hardware reports them.
- TP-Link Outlet: KLAP v1 handshake hashing for original Kasa devices whose KLAP
  firmware uses MD5-based hashes instead of the SHA-based v2 hashes.
- TP-Link Outlet: Auto mode falls back to the legacy protocol even when the KLAP
  handshake reports an auth mismatch, so transitional Kasa firmware (seen on
  KP115 1.1.1) that answers KLAP with credentials matching no known scheme stays
  reachable over the legacy protocol it still serves on port 9999.
- Verified hardware documented from live systems: EP25 over KLAP + SMART, HS300
  on KLAP firmware, KP115 and HS110 on legacy firmware, and a Tapo L930 over
  KLAP + SMART.

## v20260711 - 2026-07-11

### Added

- Forward Control4 ramp rates to the bulb as a native SMART transition, so
  brightness, color, and on/off changes fade over the programmed rate instead of
  snapping in direct mode.

### Fixed

- Restore dynamic bindings and output variables in OnDriverInit so programming
  attached to them keeps working after a Director restart.

### Changed

- Restructured the repository README as a suite overview covering both the
  TP-Link Outlet and TP-Link Light drivers, instead of embedding the outlet
  driver's documentation.

## v20260710 - 2026-07-10

### Added

- Initial release.
