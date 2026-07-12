<img alt="TP-Link" src="./images/header.png" width="500"/>

---

# <span style="color:#4ACBD6">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or TP-Link.

This suite provides local, cloud-free control of TP-Link Kasa and Tapo smart
home devices from Control4, across the generations of TP-Link's local protocols.
Older Kasa integrations rely on TP-Link's plaintext protocol on port 9999;
firmware updates rolled out since late 2024 disable that protocol and replace it
with KLAP, an encrypted local protocol, and newer Kasa hardware (e.g. the EP25
v2.6) also swaps the legacy command schema for the SMART schema that Tapo
devices speak. These drivers implement the KLAP handshake and session encryption
(both hash generations) and both command schemas, and auto-detect devices still
on the original firmware, so the same driver instance keeps working when TP-Link
migrates a device.

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

<div style="page-break-after: always"></div>

# <span style="color:#4ACBD6">System Requirements</span>

- Control4 OS 3.3+
- TP-Link (Kasa/Tapo) account credentials for devices on KLAP firmware; devices
  on original Kasa firmware need no credentials

# <span style="color:#4ACBD6">Included Drivers</span>

## TP-Link Outlet

Control Kasa smart power strips (HS300/KP303/KP400) and smart plugs. Every
output is exposed as a standard Control4 relay binding with per-output events,
variables, and real-time power readings.

**Key features:**

- Local control of each output with no TP-Link cloud dependency after setup
- KLAP encrypted transport plus automatic legacy protocol detection
- Speaks both the legacy IOT and the newer SMART command schemas, so
  SMART-firmware plugs and power strips (Kasa EP25 v2.6/KP125M/EP40M, Tapo
  P-series) work alongside classic Kasa hardware
- Standard Control4 relay binding per output
- `Output N Turned On` / `Output N Turned Off`, `Connected`, and `Disconnected`
  events
- Per-output variables (`Output N Name`, `Output N State`, `Output N Power`,
  `Voltage`) for programming
- Real-time energy monitoring per outlet with a configurable poll rate, on
  devices that support it
- Turn Output On / Turn Output Off / Toggle Output programming commands
- Output Light bindings pair with the TP-Link Light driver to present an output
  as a light

## TP-Link Light

Present a Control4 light (light_v2) backed by a TP-Link device, in one of two
modes:

**Key features:**

- **Direct mode**: connects to a TP-Link light (Tapo L900/L920/L930 strips, Tapo
  bulbs) over KLAP. Brightness, color, and color temperature are enabled
  dynamically from what the device reports
- **Proxy mode**: binds to a TP-Link Outlet output so a lamp plugged into a
  smart outlet appears as a real on/off light, with state kept in sync from the
  outlet
- Conservative capability baseline so on/off devices never advertise dimming or
  color to capability consumers
- Advanced Lighting Scenes support

<div style="page-break-after: always"></div>

# <span style="color:#4ACBD6">Installation</span>

## Installing the Drivers

1.  Download the latest `control4-tplink.zip` from
    [Github](https://github.com/finitelabs/control4-tplink/releases/latest).
2.  Extract and install the desired `.c4z` driver files.
3.  Use the "Search" tab in Composer Pro to find the driver by name and add it
    to your project.

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

<div style="page-break-after: always"></div>

# <span style="color:#4ACBD6">Support</span>

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

<https://github.com/finitelabs/control4-tplink/issues/new>

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<div style="page-break-after: always"></div>

# <span style="color:#4ACBD6">Changelog</span>

## Unreleased

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
