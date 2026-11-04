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

## Unreleased

### Added

- Added support for Tapo and Kasa devices with Third-Party Compatibility off in
  the Tapo or Kasa app to the TP-Link Outlet and TP-Link Light drivers, on
  Control4 OS 3.4.1 or later. `Protocol` has a `TPAP` choice for them, and
  `Auto` finds it.

- Added a `Fades` property to the TP-Link Light driver for Tapo lights, which
  take no fade time from a command. On `Driver`, the default, the driver makes
  the fades, so ramp rates, stops, held buttons and scene fades work; on
  `Light`, the light uses its own fades from the Tapo app.

  <!-- #ifdef DRIVERCENTRAL -->

- Added a `Support Code` property to the TP-Link Outlet and TP-Link Light
  drivers. A code from Finite Labs support opens the driver's Lua tab in
  Composer for an hour; leave it blank otherwise.

- Added a `Cloud Monitoring` property, Enabled by default, and a
  `Diagnostics Snapshot` action to every driver. Cloud Monitoring sends Finite
  Labs an hourly report of the driver's memory use and a report of each error it
  hits; the documentation says what they hold.

  <!-- #endif -->

- Added On, Off and Toggle keypad button links to each TP-Link Outlet output. A
  keypad button bound to one switches the output, and its LED follows it.

- Added `Output N In Use` and `Output N Idle` events and an `Output N In Use`
  variable to the TP-Link Outlet driver, set from each output's power and two
  levels, `In Use Above (W)` and `Idle Below (W)`. `Hold (s)` sets how long the
  power must stay past a level before the event fires.

- Added address following to the TP-Link Outlet and TP-Link Light drivers: when
  DHCP gives the device another address on the controller's network, the driver
  finds it by its MAC address and updates `IP Address` (OS 4.0 and later). A
  different device that answers at the address is not controlled. The TP-Link
  Light driver shows the light's `MAC Address`.

### Fixed

- Fixed a TP-Link device that changed protocol, as a firmware update, a rollback
  or a reset can make it do, staying disconnected until the driver was
  reconnected or the controller restarted. The driver now detects the device's
  protocol again once it has missed three polls in a row.
- Fixed an Advanced Lighting scene set to flash, with no delay or ramp time on
  any step, hanging the TP-Link Light driver. It now runs its steps once and
  stops.
- Fixed a color sent to a TP-Link light right after it was ramped on, as
  programming that turns a light on and sets its color does, being dropped. The
  light now takes it and keeps it when the ramp ends.
- Fixed a ramp that also changes a TP-Link light's color, as a ramp to on or a
  Dim-To-Warm dim does, reporting the new color as the one the fade starts from.
- Fixed a TP-Link light showing a scene's color, or going back to a color set
  while it was off, after turning on or changing level had given it its on color
  or Dim-To-Warm color.
- Fixed an Advanced Lighting scene carrying on with a TP-Link light after the
  light was turned on or off, set to a level or ramped: a later step of the
  scene took the light back, and a scene that flashes the light kept flashing
  it. The command now takes the light out of the scene.
- Fixed a ramp or color fade started while a scene was still fading a TP-Link
  light showing as finished when the scene's fade ended, while the light was
  still moving. It now shows as finished when the light gets there.
- Fixed a color set on a TP-Link light during a ramp being replaced by its
  Dim-To-Warm color when the ramp ended.
- Fixed Color On Mode set to a color preset not being applied to a TP-Link
  light: the light turned on in the color it last went off in, as if the mode
  were Previous, and with no color of its own before it had been off once. It
  now turns on in the preset's color and follows an edit of that preset.
- Fixed a TP-Link light with Color On Mode set to Previous that was faded off,
  not switched off at once, turning back on in the color it had before the fade,
  not the one it faded off in.
- Fixed a TP-Link light that was told to stop ramping during an Advanced
  Lighting scene being moved again by the scene's next step. The stop now takes
  the light out of the scene.
- Fixed a TP-Link light that was told to stop ramping while its color was still
  fading being put in its Dim-To-Warm color, or the color it turns on in, with
  the fade cut short. The stop now holds the level and leaves the color fade to
  finish.
- Fixed a TP-Link light that was stopped during a ramp losing a color set since
  the ramp began.
- Fixed a scene step that sets only a level leaving a TP-Link light in its old
  color with Dim-To-Warm. The step now takes the Dim-To-Warm color for its
  level, as other level changes do.
- Fixed Stop Scene Ramp not stopping a TP-Link light: the light carried on to
  the end of its ramp and was shown as still ramping. It now holds the light
  where the ramp has got to.
- Fixed a keypad button bound to a TP-Link light's Top, Bottom or Toggle link,
  and the light's own button actions, doing nothing.
- Fixed a held Top or Toggle button ramping a TP-Link light toward its Default
  On level, which dimmed a brighter light. A hold now ramps toward full until
  released.
- Fixed a button pressed, clicked or toggled while a TP-Link light was ramping
  acting on the level the ramp began from: a light on its way up could be
  switched off and faded up again, or toggled the wrong way.
- Fixed a scene step with no ramp time not being shown for a TP-Link light, in
  level or color, until the light reported it, so the step, command or color
  fade after it started from the old one.
- Fixed a color a TP-Link light took while it was off not being picked up until
  it was next on.
- Fixed Ramp Scene Up and Down, on a TP-Link light already ramping, starting
  from the level that ramp began at: the light could drop to its minimum and
  climb, or not move at all.
- Fixed a TP-Link light that was ramping not stopping when a command asked for
  the level it had just reached: the light carried on to the end of its ramp
  while it was shown at the level asked for.
- Fixed a TP-Link light with Dim-To-Warm between two color temperatures being
  shown in two colors at every brightness change, the one it was sent and then
  the one it reported, and being sent the level again by a command for the level
  it was already at.
- Fixed a TP-Link color light with no color temperature restarting a moment into
  a ramp to on, when it turns on in a color temperature preset.
- Fixed an Advanced Lighting scene that was deactivated, cleared or removed
  while one of its steps was fading a TP-Link light leaving the light shown as
  still ramping, at the level and color it had before the fade: a command for
  that level then did nothing, and a stop found nothing to stop. The fade now
  runs on and shows as finished when the light gets there.
- Fixed a scene step that sets only a color, run while a TP-Link light was
  ramping, making the driver lose track of the ramp: a stop then did nothing,
  and the level the light ramped to was never shown. The ramp now carries on for
  a stop to hold.
- Fixed a scene step that sets a level, run while a TP-Link light was ramping,
  starting from the level that ramp began at: the step's fade was shown from the
  wrong level and a stop held the light at the wrong one, and a step back to the
  level the ramp began at left the light shown as still ramping.
- Fixed a scene step run while a TP-Link light's color was fading: a step with a
  color of its own showed its fade from the color the earlier fade began at, and
  a step that sets only a level left the earlier fade's end never shown.
- Fixed a scene step with a ramp time showing an On/Off-only TP-Link light
  ramping to the step's level, and at that level when the ramp time had passed.
  The light switches at once and is now shown on or off as it does.
- Fixed a scene step that turns a TP-Link light on over a ramp time not fading
  it up from off as a ramped On does, and a step that sets only a level turning
  the light on without its Color On Mode color.
- Fixed a TP-Link light that was stopped during a scene step's fade, with
  Dim-To-Warm, losing the color the step set when the light was already in that
  color.
- Fixed a ramp that took over from one still changing a TP-Link light's color,
  as a button's click does from its press, showing its color fade from the color
  the first ramp was heading for.
- Fixed a ramped On of a TP-Link light cut short by a level command leaving the
  light shown as still changing color.
- Fixed a TP-Link light in direct mode resting at a level or color that was not
  the last one asked for, after presses in quick succession or a dragged slider,
  while it was shown at the last one: commands that reached the light together
  were taken in another order. The light now ends at the last level or color
  asked for.
- Fixed a TP-Link light in direct mode being shown, for a few seconds after a
  command, at the level or color it had just before it, when the driver's poll
  of the light was already on its way as the command was made.
- Fixed the TP-Link Light driver showing
  `Disconnected: Legacy: request timed out` in `Driver Status` for a light that
  was connected and working, after the username and password were entered, or
  after any two connection properties were changed a few seconds apart. It also
  could leave the driver connected over a protocol the `Protocol` property
  excludes.
- Fixed the TP-Link Outlet driver showing `Disconnected` and running its
  Disconnected programming for a device that was connected and working, after
  the username and password were entered, or after two connection properties
  were changed a few seconds apart. A TP-Link Light bound to one of its outputs
  went off in Control4 until the next poll.
- Fixed `Driver Status` of the TP-Link Light and TP-Link Outlet drivers flipping
  between `Connecting` and the reason the device was not found, every poll,
  while the driver kept trying. The reason now stays until an attempt ends
  another way.
- Fixed a TP-Link Light unbound from its outlet, or one that found no light
  after a connection property was changed or Reconnect was run, staying online
  in Navigator at its last level.
- Fixed a TP-Link light that was offline, or bound to an outlet that was, being
  shown on or off, and running its Light On or Light Off programming, for a
  command it never got. It now ignores commands until it reports again.
- Fixed the TP-Link Light and TP-Link Outlet drivers failing to connect to a
  device that was answering, until the next retry, when a connection property
  was changed or Reconnect was run while the driver was connecting.
- Fixed a change of IP address or TP-Link account, made while the driver was
  connecting, not being tried until the next retry.
- Fixed a ramped On of a TP-Link light in direct mode first switching the light
  on at the level it was last at, ahead of the fade to the level asked for.
- Fixed the TP-Link Light driver sending a light its level again when a ramp
  ended, and its color again when a color fade ended. The light already held
  both, and the extra command was one more for it to answer while others waited.
- Fixed a color picked for a Tapo light while it was off being lost: the color
  was shown for a few seconds and then went back, and the light came on in the
  color it had before. A Tapo light takes no color while it is off, so the
  driver now keeps the color and sends it with the command that turns the light
  on, unless the light's Color On Mode gives that on a color of its own.
- Fixed a color temperature outside a TP-Link light's range, which programming
  or a scene can ask for, being shown as asked and then, at the light's next
  report, as the nearest one the light can do. It is now shown once, as the
  light takes it.
- Fixed a color change sent to a TP-Link light with no ramp time being taken at
  once on a light whose default ramp rate had never been set. It now takes the
  default ramp rate, as a level change does.
- Fixed the TP-Link Light driver storing a light's brightness presets among its
  color presets, and the two together as its Color On Mode, when a preset
  reached a driver that had stored none yet.
- Fixed the TP-Link Light driver not knowing a light's Color On Mode, the level
  it turns on to, or its default ramp rate until one of them was next changed in
  Composer. A level command with no ramp time, a keypad button bound to the
  light and a scene step used half a second and no on color, where Composer
  showed three quarters of a second and Dim-To-Warm. The driver now reads them
  from the light's settings in the project when it starts.
- Fixed the TP-Link Outlet and TP-Link Light drivers printing the TP-Link
  account to the Lua output and the log: the password at `Log Level`
  `6 - Ultra`, and the username from `5 - Trace` up. Neither is printed at any
  level now.
- Fixed the TP-Link Outlet driver no longer noticing an output switched at the
  device or in the Kasa or Tapo app, or the device going offline, until the
  driver was reloaded, after a reconnect or a reply it could not read.
- Fixed a TP-Link light turned on over a ramp time being shown as off until the
  ramp ended. The light now comes on at once and is shown on from the start.
- Fixed a TP-Link light asked for its level during a ramp being shown as stopped
  at the level the ramp began from, so a light turned on over a ramp time was
  shown off again. It is now shown still ramping, from the level it has reached.
- Fixed the LEDs of keypad buttons bound to a TP-Link light showing the light
  off while it was turned on over a ramp time, until the ramp ended. They now
  show it on from the start of the ramp.
- Fixed a TP-Link light turned on over a ramp time, and stopped or turned off
  part way, having its Previous On level set to 1%. Previous On now keeps its
  level, or takes the one the light had reached.
- Fixed Max On Level and Min On Level, set on a TP-Link light in Composer,
  having no effect: a light with a Max On Level of 80 still went to 100%. The
  light's levels 1 to 100 now run between the two, as on a Control4 dimmer, for
  every level it is sent and shown. A change of either leaves the light where it
  is, shown at its level on the new range, until its next level command moves it
  onto the range.
- Fixed a TP-Link light running its Brightness Changed or Color Changed
  Programming after a controller restart, and one in a color, or at a level
  under a Max and Min On Level, running it when the driver was updated or
  reconnected, as Control4 was told the light's level and color again. It is now
  told only a level, color or capability that differs from the one it shows.
  After a controller restart Control4 still reports the color variables of a
  light with color or color temperature as changed, as it learns the light's
  capabilities again.
- Fixed a TP-Link light that only switches, a light bound to a TP-Link Outlet
  output, running its Level Change Programming after a controller restart, and
  its Light Off and Light On Programming when the driver was updated with the
  light on. Control4 asks such a light for its level as it connects, before the
  light has answered, and was told it was off. The light's level is now told
  once the light answers, and only if it differs from the one shown.
- Fixed a TP-Link light's color in Navigator and in its variables staying on the
  old color after a color preset was picked, one of the Color Agent's or one of
  the light's own, or after the Control4 app turned the light on in its Color On
  Mode color. The light itself changed color.
- Fixed a relay driver connected to a TP-Link Outlet output running its
  programming for the relay closing or opening when it was connected, though the
  output had not changed. A relay driver that asks for the output's state is now
  told it.
- Fixed a TP-Link Outlet output switched while a poll was under way being shown
  in its old state for a moment, which ran its On or Off programming, and that
  of a relay or TP-Link Light bound to it, a second time.
- Fixed a TP-Link Light bound to a TP-Link Outlet output being shown online, in
  its last state, when it reconnected or was bound while the plug was offline,
  which could run its Light On programming.
- Fixed the LEDs of keypad buttons bound to a TP-Link light staying lit when the
  light went offline. They now show it off.
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed changing `Automatic Updates` or `Update Channel` on a TP-Link Outlet or
  TP-Link Light driver briefly holding up every other one, longer in a project
  with many, while the change was copied to them.
  <!-- #endif -->

### Changed

<!-- #ifdef DRIVERCENTRAL -->

- The TP-Link Outlet and TP-Link Light drivers stop reaching their device after
  five minutes without an active license and show `No active license` in Driver
  Status. Outputs keep the state they showed and lights show offline at their
  level, with no event and no Light Off. A license starts them again at once.

<!-- #endif -->

- With Dim-To-Warm, a color an Advanced Lighting scene sets on a TP-Link light
  that is on now stays when the light is dimmed or brightened, until it turns
  off, as a color set from a Navigator or programming does.
- With Dim-To-Warm, a brightness command for the level a TP-Link light is
  already at now returns a color set on it from the Tapo app to its Dim-To-Warm
  color. It used to do nothing.
- The TP-Link Light driver now shows a light as a dimmer until it connects, and
  turns dimming off once it finds the light only switches, as a lamp on a
  TP-Link Outlet output does. This should stop Composer showing "Error setting
  default color rate from driver" at a color light's first connect. A lamp on a
  TP-Link Outlet is shown as a dimmer until the outlet first reports, and stays
  one to other drivers that read only its declared type.
- The TP-Link Outlet driver's `Kasa Settings` are now `TP-Link Settings`, and
  its documentation names Tapo plugs and power strips alongside Kasa.
- The TP-Link Outlet driver's `Log Mode` now goes back to `Off` after 3 hours,
  as the TP-Link Light driver's does, and `Log Level` goes back to `3 - Info`
  while logging is off.
  <!-- #ifdef DRIVERCENTRAL -->
- Changing `Automatic Updates` on any TP-Link Outlet or TP-Link Light driver now
  changes it on all of them, so the drivers update together.
  <!-- #endif -->
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
