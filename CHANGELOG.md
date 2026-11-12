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

### Changed

- After a driver restart or a reconnect the TP-Link Light reports its brightness
  and color to Control4 as it finds them, even when they have not changed.
- A command for the brightness or color the TP-Link Light already shows no
  longer fires a change event in Control4 programming.
- The TP-Link Light answers brightness queries with the level it last reported,
  also during a fade or while the device can't be reached.
- Keypad buttons with no colors of their own show the TP-Link Light's colors
  from Composer, then the standard defaults.
- Turning a TP-Link Light on fades its color to the on color over the same time
  as its brightness.
- With Dim-To-Warm, turning the TP-Link Light off fades its color all the way to
  the Dim color.
- With Dim-To-Warm, the color blends in a straight line between the Dim and On
  colors, whites included, and reports the white the TP-Link Light shows.
- A new fade starts from where the TP-Link Light is, even in the middle of
  another fade.
- With Dim-To-Warm, a color set by a scene step gives way to Dim-To-Warm at the
  next brightness change.
- Choosing the color a TP-Link Light is already fading to holds that color, as
  any chosen color does.
- A color chosen while the TP-Link Light is off is kept when another app turns
  the light on.
- A color set while a TP-Link Light fades to off is not saved for the next time
  it turns on.
- A TP-Link Light turned back on before its fade to off ends keeps the color it
  had.
- A keypad press on a dimmable TP-Link Light waits 250 ms to tell a click from a
  hold, and a click fades over the click rate.
- A keypad hold takes time in proportion to the distance it has left, and
  letting go stops only a hold or a scene ramp.
- Toggle buttons alternate their hold direction after each ramp, and a Toggle
  press while the TP-Link Light fades up from off keeps it coming on.
- Ramp Scene Up ramps to full brightness rather than the on level.
- Stop Scene Ramp lets a scene step's fade finish and stops Ramp Scene Up or
  Down where it is.
- A stop or an off just after a TP-Link Light starts fading on leaves it at its
  lowest level, and the next on returns there.
- A brightness change that retimes a color fade already under way reports the
  fade's new timing.
- The TP-Link Light reports a setting back to Control4 only when it changes, not
  at every start.
- A TP-Link Light that only switches on and off changes and reports at once,
  with no fade.
- Turning a TP-Link Light off right after changing its color no longer loses
  that color.
- A command the TP-Link Light does not take is corrected in Control4 within 2
  seconds instead of at the next poll.
- The TP-Link Light reports that it is back online after a reconnect.
- A color chosen while a TP-Link Light is off is applied when it next turns on.
- Stopping a fade the driver runs leaves the TP-Link Light exactly where the
  fade had got to.
- Fades the driver runs move in steps every 100 ms, can last up to a day, and
  stay between the TP-Link Light's Min and Max On levels.
- A fade the driver runs from off lights the TP-Link Light at once at its Min On
  level, and a color set during the fade goes at once.
- Kasa lights offer fades of up to 60 seconds.

<!-- #ifdef DRIVERCENTRAL -->

## v20261110 - 2026-11-10

### Added

- Added the TP-Link Outlet and TP-Link Light drivers to DriverCentral.

<!-- #endif -->

<!-- #ifndef DRIVERCENTRAL -->

## v20261109 - 2026-11-09

### Fixed

- Fixed a color sent to a light that is off or turning off, by a command or a
  scene step, turning the light on or being lost, so it is now kept for the
  light's next on.
- Fixed a color set while a light is off giving way to its Color On Mode at the
  next on, so the light now comes on in that color.
- Fixed a scene step's color turning on a dimmer or switch that cannot show
  color.
- Fixed a fade from a color to a white jumping to the warmest white when stopped
  part way, or to white at its start on a Tapo light.
- Fixed Stop Brightness Change not stopping a fade on a light without color,
  which takes a controller restart for a light already in the project.
- Fixed a keypad button bound to a light's or an outlet's Button Link not
  showing its colors and LED state.
- Fixed keypad buttons on a light's Button Links showing default colors in place
  of the project's button LED colors, which can now be set for each light in
  Composer.

## v20261105 - 2026-11-05

### Added

- Added support for Tapo and Kasa devices with Third-Party Compatibility off in
  the Tapo or Kasa app, on Control4 OS 3.4.1 or later, with a new TPAP choice
  for Protocol that Auto finds.
- Added a Fades property to the TP-Link Light driver, so the driver makes a Tapo
  light's fades for ramp rates, stops, held buttons and scenes, or leaves them
  to the light.
- Added On, Off and Toggle keypad button links to each TP-Link Outlet output,
  with the button's LED following the output.
- Added Output N In Use and Output N Idle events and an Output N In Use variable
  to the TP-Link Outlet driver, set by each output's power against levels and a
  hold time you choose.
- Added address following to the TP-Link Outlet and TP-Link Light drivers, which
  find a device again by its MAC address when its IP address changes, on OS 4.0
  and later.

### Fixed

- Fixed ramps and stops on TP-Link lights, so a stop holds the light where it is
  and a ramp starts from where the light is.
- Fixed keypad buttons on TP-Link lights, so Top, Bottom and Toggle links and
  the light's own button actions work, and a held button ramps until released.
- Fixed Advanced Lighting scenes on TP-Link lights, so each step fades from
  where the light is, a command takes the light out of the scene, and a flash
  with no delay no longer hangs the driver.
- Fixed colors on TP-Link lights, so a Color On Mode preset, Previous and a
  color set during a ramp or while the light is off all work.
- Fixed Dim-To-Warm on TP-Link lights, so a scene step that sets only a level
  takes the Dim-To-Warm color, and a color set during a ramp or a scene step
  stays.
- Fixed Max On Level and Min On Level having no effect on TP-Link lights.
- Fixed a TP-Link light turned on over a ramp time, then stopped or turned off
  part way, setting its Previous On level to 1%.
- Fixed a TP-Link light ending at a level or color other than the last one asked
  for, after quick presses or a dragged slider.
- Fixed TP-Link lights sometimes shown at the wrong level or color after a
  command, a color preset, a ramp or a scene.
- Fixed the TP-Link Light driver not knowing a light's Color On Mode, on level
  or default ramp rate until one of them was changed in Composer.
- Fixed the TP-Link Light driver storing a light's brightness presets among its
  color presets.
- Fixed TP-Link lights running their Brightness Changed, Color Changed, Level
  Change, Light On or Light Off programming after a controller restart or a
  driver update when nothing had changed.
- Fixed a TP-Link light that was offline, or bound to an outlet that was, being
  shown on or off, and running its programming, for a command it never got.
- Fixed a TP-Link Light shown online in its last state when it had no light or
  outlet to reach.
- Fixed the LEDs of keypad buttons bound to a TP-Link light showing the wrong
  state during a ramped On and after the light went offline.
- Fixed a TP-Link device that changed protocol after a firmware update, a
  rollback or a reset staying disconnected.
- Fixed the TP-Link drivers showing Disconnected for a connected device after
  connection properties were changed a few seconds apart.
- Fixed Driver Status flipping at every poll while a device was not found, and a
  connection change made during a connect waiting for the next retry.
- Fixed the TP-Link Outlet driver sometimes missing an output switched at the
  device, or the device going offline, until it was reloaded.
- Fixed a TP-Link Outlet output switched during a poll running its programming
  twice.
- Fixed a relay driver connected to a TP-Link Outlet output running its
  programming when connected, or reading the output's state as unverified after
  a controller restart.
- Fixed the TP-Link Outlet and TP-Link Light drivers printing the TP-Link
  account to the Lua output and the log at high log levels.
  <!-- #ifndef DRIVERCENTRAL -->
- Fixed changing Automatic Updates or Update Channel on one TP-Link driver
  briefly holding up the others.
  <!-- #endif -->

### Changed

- Changed Dim-To-Warm to keep a color an Advanced Lighting scene sets until the
  light turns off, as it keeps one set from Navigator or programming.
- Changed Dim-To-Warm so a brightness command for the level a light is already
  at returns a color set from the Tapo app to the Dim-To-Warm color.
- Changed the TP-Link Light driver to show a light as a dimmer until it
  connects, then turn dimming off for a light that only switches.
- Changed the TP-Link Outlet driver's Kasa Settings to TP-Link Settings, and its
  documentation now covers Tapo plugs and power strips.
- Changed the TP-Link Outlet driver's Log Mode to go back to Off after 3 hours,
  as the TP-Link Light driver's does.
- Changed the TP-Link Outlet driver's Output N State properties to read On or
  Off.

## v20261002 - 2026-10-02

### Changed

- Changed Driver Status to say when a device refuses to connect because
  Third-Party Compatibility is off in the Tapo or Kasa app, and how to fix it.

<!-- #ifndef DRIVERCENTRAL -->

### Fixed

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.

<!-- #endif -->

## v20260714 - 2026-07-14

### Fixed

- Fixed the TP-Link Outlet driver silently failing to switch each output of some
  older multi-outlet plugs.

## v20260713 - 2026-07-13

### Added

- Added support for older Kasa KL and LB bulbs and light strips to the TP-Link
  Light driver, with no TP-Link account needed on their original firmware.
- Added a Protocol property and a Reconnect action to the TP-Link Light driver,
  as on the TP-Link Outlet driver, and Driver Status names the protocol in use.

### Changed

- Changed the TP-Link Light driver's Driver Status for Tapo lights to name the
  SMART protocol, as the TP-Link Outlet driver does.

## v20260712 - 2026-07-12

### Added

- Added support for newer Kasa and Tapo plugs to the TP-Link Outlet driver,
  which needs the TP-Link account to reach them.
- Added each outlet of newer multi-outlet plugs and power strips to the TP-Link
  Outlet driver, with each outlet's energy readings where the device reports
  them.
- Added support in the TP-Link Outlet driver for Kasa devices on early and
  transitional KLAP firmware.

## v20260711 - 2026-07-11

### Added

- Added Control4 ramp rates to TP-Link lights, so brightness, color and on and
  off changes fade instead of snapping.

### Fixed

- Fixed programming on the drivers' connections and output variables stopping
  after a controller restart.

## v20260710 - 2026-07-10

### Added

- Initial release.

<!-- #endif -->
