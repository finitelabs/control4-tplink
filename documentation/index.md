<!-- Copyright 2026 Finite Labs, LLC. All rights reserved. -->

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
   [DriverCentral](https://drivercentral.io/platforms/control4-drivers/lighting/tp-link-kasa-and-tapo).
1. Extract and install the desired `.c4z` driver files.
1. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

<!-- #else -->

1. Download the latest `control4-tplink.zip` from
   [GitHub](https://github.com/finitelabs/control4-tplink/releases/latest).
1. Extract and install the desired `.c4z` driver files.
1. Use the "Search" tab in Composer Pro to find the driver by name and add it to
   your project.

<!-- #endif -->

Each driver includes its own documentation accessible from within Composer Pro.
Refer to the individual driver documentation for detailed property descriptions,
programming reference, and configuration guides.

<!-- #ifdef DRIVERCENTRAL -->

# <span style="color:#4ACBD6">Developer Information</span>

<p align="center">
<img alt="Finite Labs" src="./images/finite-labs-logo.png" width="400"/>
</p>

Copyright © 2026 Finite Labs LLC

All information contained herein is, and remains the property of Finite Labs LLC
and its suppliers, if any. The intellectual and technical concepts contained
herein are proprietary to Finite Labs LLC and its suppliers and may be covered
by U.S. and Foreign Patents, patents in process, and are protected by trade
secret or copyright law. Dissemination of this information or reproduction of
this material is strictly forbidden unless prior written permission is obtained
from Finite Labs LLC. For the latest information, please visit
https://drivercentral.io/platforms/control4-drivers/lighting/tp-link-kasa-and-tapo

<!-- #endif -->

# <span style="color:#4ACBD6">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating these drivers with Control4 or
your TP-Link devices, you can contact us at
[%%SUPPORT_EMAIL%%](mailto:__SUPPORT_EMAIL__) or call/text us at
[%%SUPPORT_PHONE%%](tel:__SUPPORT_PHONE__).

<!-- #else -->

If you have any questions or issues integrating these drivers with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-tplink/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->
