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

- Added Button Lit Color and Button Unlit Color properties to the TP-Link Outlet
  driver, which set the LED colors of keypad buttons on its Button Links. They
  start as the project's button LED colors, and a Reset Button Colors action
  takes those again.
- Added Control4 load groups to the TP-Link Light: it joins a load group and
  follows the group's level, ramps and sync.

### Fixed

- Fixed a TP-Link Light or Outlet showing offline after missing a poll or two.
  It now shows offline only once three polls in a row go unanswered.
- Fixed a light command or an outlet switch the device does not answer marking
  it offline.
- Fixed a TP-Link Light coming on at a removed brightness preset's level when
  that preset was its on mode.

### Changed

- Changed a TP-Link Light that can't be reached to show offline and keep its
  level and keypad button LEDs until it answers again, where it used to show
  off.
- Changed the TP-Link Light to report its brightness and color to Control4 as it
  finds them after a driver restart or a reconnect, even when they have not
  changed.
- Changed the TP-Link Light to no longer fire a change event in Control4
  programming for a brightness or color command it already shows.
- Changed the TP-Link Light to answer brightness queries with the level it last
  reported, also during a fade or while the device can't be reached.
- Changed keypad buttons with no colors of their own to show the TP-Link Light's
  colors from Composer, then the standard defaults.
- Changed a TP-Link Light turned on to be in its on color wherever its
  brightness stops, and under Dim-To-Warm its color to follow its brightness.
- Changed a TP-Link Light turned off under Dim-To-Warm to show in its Dim color,
  the color it next comes on in.
- Changed the Dim-To-Warm color to blend in a straight line between the Dim and
  On colors, whites included, and report the white the TP-Link Light shows.
- Changed a new fade to start from where the TP-Link Light is, even in the
  middle of another fade.
- Changed a color set by a scene step under Dim-To-Warm to give way to
  Dim-To-Warm at the next brightness change.
- Changed choosing the color a TP-Link Light is already fading to so it holds
  that color, as any chosen color does.
- Changed a color chosen while the TP-Link Light is off to be kept when another
  app turns the light on.
- Changed a color set while a TP-Link Light fades to off to not be saved for the
  next time it turns on.
- Changed a TP-Link Light turned back on before its fade to off ends to keep the
  color it had.
- Changed a keypad press on a dimmable TP-Link Light to wait 250 ms to tell a
  click from a hold, and a click to fade over the click rate.
- Changed a keypad hold to take time in proportion to the distance it has left,
  and letting go to stop only a hold or a scene ramp.
- Changed Toggle buttons to alternate their hold direction after each ramp, and
  a Toggle press while the TP-Link Light fades up from off to keep it coming on.
- Changed Ramp Scene Up to ramp to full brightness rather than the on level.
- Changed Stop Scene Ramp to let a scene step's fade finish and stop Ramp Scene
  Up or Down where it is.
- Changed a stop or an off just after a TP-Link Light starts fading on to leave
  it at its lowest level, and the next on to return there.
- Changed a brightness change that retimes a color fade already under way to
  report the fade's new timing.
- Changed the TP-Link Light to report a setting back to Control4 only when it
  changes, not at every start.
- Changed a TP-Link Light that only switches on and off to change and report at
  once, with no fade.
- Changed turning a TP-Link Light off right after changing its color to no
  longer lose that color.
- Changed a command the TP-Link Light does not take to be corrected in Control4
  within 2 seconds instead of at the next poll.
- Changed the TP-Link Light to report that it is back online after a reconnect.
- Changed a color chosen while a TP-Link Light is off to be applied when it next
  turns on.
- Changed stopping a fade the driver runs to leave the TP-Link Light exactly
  where the fade had got to.
- Changed fades the driver runs to move in steps every 100 ms, last up to 999999
  ms or about 16 minutes, and stay between the TP-Link Light's Min and Max On
  levels.
- Changed a fade the driver runs from off to light the TP-Link Light at once at
  its Min On level, and a color set during the fade to go at once.
- Changed Kasa lights to offer fades of up to 60 seconds.

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

- Added the TP-Link Light and TP-Link Outlet drivers.

<!-- #endif -->
