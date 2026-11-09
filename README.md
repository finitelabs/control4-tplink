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

## Unreleased

### Fixed

- Fixed a scene step that sets only a color turning on a light that is off. The
  color is now kept for the light's next on, as a color command's is.
- Fixed a color sent to a Kasa light that is fading to off turning it back on.
  The light now goes off and keeps the color for its next on.
- Fixed a color set on a Kasa light while it is off, or turning off, being lost:
  the light dropped it. The color is now kept for the light's next on, as it is
  on a Tapo light.
- Fixed a scene step's color on a light that cannot show it. A dimmer or switch
  no longer turns on for it, and Control4 is no longer told of a color fade the
  light cannot make.
- Fixed a fade from a color to a white. A stop part way now holds the color the
  light has got to, where it sent a color temperature that took the light to its
  warmest white, and a fade on a Tapo light now goes through the colors between
  instead of jumping to white at its start.
- Fixed Stop Brightness Change from Control4 programming or the app not stopping
  a fade on a light without color. Control4 passes that stop only to a light
  that has a color stop, which every light that dims now has. A light already in
  a project takes this at the controller's next restart.
- Fixed a keypad button bound to a light's or an outlet's Button Link getting no
  answer when it asks for its colors and LED state. It is now answered on its
  link, and a light's button colors changed in Composer show on it at once.

### Changed

- Changed Log Level in the DriverCentral build to stop at `4 - Debug`:
  `5 - Trace` and `6 - Ultra` are offered only while a Support Code from Finite
  Labs support has the Lua tab open, and a driver set to either goes back to
  `4 - Debug`.

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
- Fixed changing `Automatic Updates` or `Update Channel` on one TP-Link driver
  briefly holding up the others while the change was copied to them.

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

### Fixed

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.

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
