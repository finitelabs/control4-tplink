[copyright]: # "Copyright 2026 Finite Labs, LLC. All rights reserved."

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="TP-Link" src="./images/header.png" width="500"/>

---

# <span style="color:#4ACBD6">Overview</span>

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or TP-Link.

<!-- #endif -->

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
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Installing the Drivers](#installing-the-drivers)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)
  <!-- #endif -->
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

- **Direct mode**: connects to a TP-Link light — Tapo L900/L920/L930 strips and
  Tapo bulbs over KLAP + SMART, or legacy Kasa KL/LB-series bulbs and light
  strips over KLAP or port 9999 with the IOT schema, auto-detected. Brightness,
  color, and color temperature are enabled dynamically from what the device
  reports
- **Proxy mode**: binds to a TP-Link Outlet output so a lamp plugged into a
  smart outlet appears as a real on/off light, with state kept in sync from the
  outlet
- Conservative capability baseline so on/off devices never advertise dimming or
  color to capability consumers
- Advanced Lighting Scenes support

<div style="page-break-after: always"></div>

# <span style="color:#4ACBD6">Installation</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Installing the Drivers](#installing-the-drivers).

This driver suite relies on the DriverCentral Cloud driver to manage licensing
and automatic updates. If you are new to using DriverCentral you can refer to
their [Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver)
documentation for setting it up.

<!-- #endif -->

## Installing the Drivers

<!-- #ifdef DRIVERCENTRAL -->

1. Download the latest `control4-tplink.zip` from
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/).
2. Extract and install the desired `.c4z` driver files.
3. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

<!-- #else -->

1. Download the latest `control4-tplink.zip` from
   [Github](https://github.com/finitelabs/control4-tplink/releases/latest).
2. Extract and install the desired `.c4z` driver files.
3. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

<!-- #endif -->

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

<div style="page-break-after: always"></div>

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#4ACBD6">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright &copy; 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC.

<!-- #endif -->

# <span style="color:#4ACBD6">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating these drivers with Control4 or
your TP-Link devices, you can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-tplink/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<div style="page-break-after: always"></div>

<!-- #embed-changelog -->
