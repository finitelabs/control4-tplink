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

- Fixed an Advanced Lighting scene set to flash, with no delay or ramp time on
  any step, hanging the TP-Link Light driver. It now runs its steps once and
  stops.
- Fixed a color sent to a TP-Link light right after it was ramped on, as
  programming that turns a light on and sets its color does, being dropped. The
  light now takes it and keeps it when the ramp ends.
- Fixed a ramp that also changes a TP-Link light's color, on to the color it
  turns on in or with Dim-To-Warm, reporting the new color as the one the fade
  starts from.
- Fixed a TP-Link light being shown in a scene's color, or going back to a color
  set while it was off, after a level change or a turn-on had given it its
  Dim-To-Warm color or the color it turns on in.
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

### Changed

- With Dim-To-Warm, a color set on a TP-Link light now lasts until its
  brightness next changes, when the light takes its Dim-To-Warm color again. It
  used to last until the light was turned off.

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
