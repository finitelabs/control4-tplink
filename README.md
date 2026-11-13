<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

<img alt="TP-Link" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#4ACBD6">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or TP-Link.

This suite gives Control4 local control of TP-Link Kasa and Tapo smart plugs,
power strips and lights, with no TP-Link cloud. It works with Kasa devices on
original firmware, with Kasa devices TP-Link has updated since late 2024, and
with Tapo devices and newer Kasa models. The drivers work out how each device
connects, so a device keeps working when TP-Link updates its firmware.

# <span style="color:#4ACBD6">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Included Drivers](#included-drivers)
  - [TP-Link Outlet](#tp-link-outlet)
  - [TP-Link Light](#tp-link-light)
- [Installation](#installation)
  - [Installing the Drivers](#installing-the-drivers)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#4ACBD6">System Requirements</span>

- Control4 OS 3.3+
- TP-Link (Kasa or Tapo) account credentials for Tapo devices and for Kasa
  devices updated since late 2024; Kasa devices on original firmware need none
- Devices on newer firmware work with **Third-Party Compatibility** on or off in
  the Tapo or Kasa app. With it off they need Control4 OS 3.4.1 or later

# <span style="color:#4ACBD6">Included Drivers</span>

## TP-Link Outlet

Control Kasa and Tapo smart plugs and power strips. Every output is exposed as a
standard Control4 relay binding with per-output events, variables, and real-time
power readings.

**Key features:**

- Local control of each output with no TP-Link cloud dependency after setup
- Works on original Kasa firmware and on the firmware TP-Link has rolled out
  since late 2024, and works out which one a device runs
- Tapo plugs and power strips and newer Kasa models work alongside older Kasa
  ones
- Standard Control4 relay binding per output
- `Output N Turned On` / `Output N Turned Off`, `Connected`, and `Disconnected`
  events
- Per-output variables (`Output N Name`, `Output N State`, `Output N Power`,
  `Output N In Use`, `Voltage`) for programming
- Real-time energy monitoring per outlet with a configurable poll rate, on
  devices that support it
- Turn Output On / Turn Output Off / Toggle Output programming commands
- On, Off and Toggle keypad button links per output, with LEDs that follow it
- `Output N In Use` / `Output N Idle` events from each output's power, with two
  levels and a hold time you set
- Follows the device to a new protocol after a firmware update, a rollback or a
  reset, and to a new address on the controller's network (OS 4.0 and later)
- Output Light bindings pair with the TP-Link Light driver to present an output
  as a light

## TP-Link Light

A Control4 light backed by a TP-Link device, in direct mode or proxy mode.

**Key features:**

- **Direct mode**: connects to a TP-Link light on your network: a Tapo L900,
  L920 or L930 light strip, a Tapo bulb, or a Kasa KL- or LB-series bulb or
  light strip, on original or newer firmware. The driver works out how the light
  connects. Brightness, color and color temperature are offered when the light
  has them
- **Proxy mode**: binds to a TP-Link Outlet output so a lamp plugged into a
  smart outlet appears as a real on/off light, with state kept in sync from the
  outlet
- An on/off device is shown without dimming or color once the driver has
  connected to it
- Ramp rates, stops, held buttons and scene fades on Tapo lights, which take no
  fade time from a command: the driver makes the fade in steps, or leaves it to
  the light's own fades
- Advanced Lighting Scenes support
- Follows the light to a new protocol after a firmware update, a rollback or a
  reset, and to a new address on the controller's network (OS 4.0 and later)

# <span style="color:#4ACBD6">Installation</span>

## Installing the Drivers

1. Download the latest `control4-tplink.zip` from
   [GitHub](https://github.com/finitelabs/control4-tplink/releases/latest).
1. Extract and install the desired `.c4z` driver files.
1. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

# <span style="color:#4ACBD6">Support</span>

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-tplink/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

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
- Fixed keypad buttons on an outlet's Button Links showing their own colors in
  place of the project's button LED colors.

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
- Fixed changing Automatic Updates or Update Channel on one TP-Link driver
  briefly holding up the others.

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

### Fixed

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.

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
