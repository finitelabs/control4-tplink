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

<!-- #ifndef DRIVERCENTRAL -->

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or TP-Link.

<!-- #endif -->

The TP-Link Light driver presents a Control4 light (light_v2) backed by a
TP-Link device. It operates in one of two modes:

- **Direct mode**: the driver connects to a TP-Link light over the local
  network: a Tapo L900/L920/L930 light strip or Tapo bulb speaking the SMART
  command schema over KLAP, or a legacy Kasa KL/LB-series bulb or light strip
  speaking the IOT schema over KLAP or the original port 9999 protocol. The
  transport and schema are auto-detected. Brightness, color, and color
  temperature are supported when the device reports them.
- **Proxy mode**: the driver's TP-Link Outlet connection is bound to an output
  of the TP-Link Outlet driver. The light is then an on/off switch light backed
  by that outlet, useful for lamps and fixtures plugged into a smart outlet.

A bound outlet takes priority: while the connection is bound, the network
properties are hidden and ignored.

All standard light features are available and gate on what the device supports:
on/off, brightness with target ramps and stop, color and color temperature with
ramps, click/hold button rates, advanced lighting scenes, brightness and color
presets, and dim-to-warm color on-mode.

A Tapo light takes no fade time from a command: its only fades are the short
ones set in the Tapo app. The `Fades` property chooses who makes a fade on such
a light, the driver or the light. A Kasa bulb takes the fade time with each
command and fades by itself.

# <span style="color:#4ACBD6">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  <!-- #ifdef DRIVERCENTRAL -->
  - [DriverCentral Cloud Setup](#drivercentral-cloud-setup)
  <!-- #endif -->
  - [Driver Installation](#driver-installation)
  - [Driver Properties](#driver-properties)
  - [Connections](#connections)
- [Programming](#programming)
- [Troubleshooting](#troubleshooting)
  <!-- #ifdef DRIVERCENTRAL -->
- [Developer Information](#developer-information)
  <!-- #endif -->
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#4ACBD6">System Requirements</span>

- Control4 OS 3.3+
- Direct mode: a TP-Link light on a network reachable from the controller.
  Devices on KLAP firmware (Tapo bulbs and light strips, and firmware-updated
  Kasa bulbs) also need the TP-Link account credentials they are bound to; Kasa
  KL/LB-series bulbs on original firmware need no credentials. Devices on newer
  firmware must also have **Third-Party Compatibility** enabled (Tapo app:
  `Me → Tapo Lab → Third-Party Compatibility`; Kasa app:
  `Settings → Third-Party Compatibility`). If a device refuses to connect while
  it is already on, turn it off and back on (see
  [Troubleshooting](#troubleshooting))
- Proxy mode: a configured TP-Link Outlet driver instance

**Verified hardware:**

| Device | Type        | Features                      | Mode   |
| ------ | ----------- | ----------------------------- | ------ |
| L930-5 | Light strip | Brightness, color, color temp | Direct |
| KL130  | Bulb        | Brightness, color, color temp | Direct |
| HS110  | Smart plug  | On/off via outlet binding     | Proxy  |
| KP115  | Smart plug  | On/off via outlet binding     | Proxy  |

Other Kasa KL/LB-series bulbs (e.g. KL110, KL120, KL125, KL135, LB-series) and
Kasa light strips (KL400/KL420/KL430) speak the same IOT schema (strips take
commands through their own lighting module, which the driver selects
automatically) and are expected to work in direct mode across firmware
generations. Starting any light command from Control4 takes over from a lighting
effect running on a strip; effects themselves are not controllable from
Control4.

# <span style="color:#4ACBD6">Installer Setup</span>

<!-- #ifdef DRIVERCENTRAL -->

## DriverCentral Cloud Setup

> If you already have the
> [DriverCentral Cloud driver](https://drivercentral.io/platforms/control4-drivers/utility/drivercentral-cloud-driver/)
> installed in your project you can continue to
> [Driver Installation](#driver-installation).

This driver relies on the DriverCentral Cloud driver to manage licensing and
automatic updates. If you are new to using DriverCentral you can refer to their
[Cloud Driver](https://help.drivercentral.io/407519-Cloud-Driver) documentation
for setting it up.

<!-- #endif -->

## Driver Installation

1. Install the `tplink_light.c4z` driver (distributed in the same package as the
   TP-Link Outlet driver).
1. Use the "Search" tab to find the "TP-Link Light" driver and add it to the
   room the light lives in.
1. For direct mode, set the [IP Address](#ip-address) property, plus the TP-Link
   credential properties for devices on KLAP firmware. For proxy mode, bind the
   driver's TP-Link Outlet connection to an output of a TP-Link Outlet driver
   instead.
1. `Driver Status` shows the connection and the detected transport/schema:
   `Connected (SMART)` (KLAP, Tapo-class), `Connected (KLAP)` (KLAP, KL-series
   bulb), `Connected (Legacy)` (port 9999), or `Connected (Outlet)` in proxy
   mode. If the driver fails to connect, set `Log Mode` to `Print`, run the
   `Reconnect` action, and check the lua output window.

## Driver Properties

### Driver Status (read-only)

Displays the current status of the driver.

### Log Level / Log Mode

Standard logging controls. Log mode expires after 3 hours.

### IP Address

IP address of the light device for direct mode. Leave blank when bound to an
outlet. Use a DHCP reservation so it does not change.

### Protocol \[ **_Auto_** | KLAP | Legacy \]

Selects the local protocol for direct mode. `KLAP` is the encrypted protocol of
Tapo lights, and of Kasa KL/LB-series bulbs and light strips on firmware updated
since late 2024. `Legacy` is the port 9999 protocol of Kasa KL/LB-series bulbs
and light strips on original firmware.

`Auto` (default) tries KLAP first when credentials are set and falls back to the
legacy protocol; without credentials it connects over the legacy protocol
directly. Over KLAP it probes the SMART schema, then the IOT bulb schema, with
both KLAP hash generations. Pin it to `KLAP` or `Legacy` only if you need to
skip detection.

### TP-Link Username / TP-Link Password

Credentials of the TP-Link (Kasa/Tapo) account the device is bound to. The email
is case sensitive. Used only for the local KLAP handshake in direct mode; the
driver never contacts TP-Link's cloud. Required for KLAP firmware; may be left
blank for KL-series bulbs on original firmware.

### Poll Rate (Seconds) [ 2 - 300 ]

How often the light state is polled in direct mode. Default is `5`.

### Fades \[ **_Driver_** | Light \]

Who makes a fade on a light that takes no fade time from a command. A Tapo light
is one: whatever ramp rate it is sent, it changes over its own short fades, the
ones set in the Tapo app. The property is shown only while such a light is
connected. A Kasa bulb fades over the time each command carries, and a light
bound to an outlet only switches, so neither has the choice.

- `Driver` (default): the driver makes the fade. It sends the light a new level
  or color as fast as the light answers, a few times a second, until the fade
  ends. Ramp rates, stops, held buttons and scene fades work as they do on other
  lights. What it costs:
  - A fade sends the light a request each time the level or the color has moved
    on and the light has answered the last one, at most ten a second. A Tapo
    light strip answers about five a second: a quick fade skips levels to keep
    up, and a slow one is a request for each level it crosses, 100 from off to
    full however long it takes.
  - A quick fade is a few coarse steps: an on over 750 ms is three or four. The
    light takes each step over its own fade between states where that is on in
    the Tapo app, and at once where it is off.
  - A level or an off set from the Tapo app or another controller during a fade
    is mostly overridden by the fade's next step. The driver ends the fade and
    leaves the light as it was set only if it polls the light first, which is
    seldom in a quick fade and common in one so slow that the level moves less
    often than the light is polled.
  - A fade ends where it is if the light stops answering part way, or if the
    driver reconnects to it: Control4 shows where the light is when it next
    answers.
  - After a fade to off the light itself remembers the last step it was sent on
    the way down, so it comes on dim when it is turned on from the Tapo app.
    Control4 always turns it on at a level of its own.
- `Light`: the light fades by itself. When `Light` is chosen, and each time the
  light connects, the driver switches on the light's own fades that are off (to
  on, to off and between two states), each at the length already set in the Tapo
  app. A change is then one command, and Control4 shows the light's own fade:
  the length set for an on or an off, and about a second between two states. An
  older Tapo light has one switch for all its fades and gives no length for
  them, and some report no fade between two states: the driver switches on what
  the light has, and Control4 shows a change it has no length for at once. What
  it costs:
  - Ramp rates are the light's. A rate set in Composer, on a keypad or in a
    scene does nothing, though a scene still waits out a step's ramp time before
    its next step.
  - A stop does nothing, and a held button takes the light all the way up or
    down. A click is two commands: its press is sent as a hold, to full or to
    off, and the click's own level after it.
  - The fades the driver switched on stay on when `Driver` is chosen again.

## Driver Actions

### Reconnect

Discard any established sessions, re-run protocol detection, and reconnect.

## Connections

- **Light**: the light_v2 proxy consumed by rooms, keypads, and scenes.
- **TP-Link Outlet**: bind to an `Output N Light` connection of a TP-Link Outlet
  driver for proxy mode.
- **On / Off / Toggle Button Link**: standard button links with LED state
  tracking.

# <span style="color:#4ACBD6">Programming</span>

The driver exposes the standard Control4 light programming surface: light level
events and commands, advanced scene support, brightness and color presets, and
click/hold rates. In proxy mode the light is on/off only and brightness
collapses to 0/100. A level or color the light still has when the driver starts,
is updated or reconnects runs no Brightness Changed or Color Changed
programming. After a controller restart Control4 still reports the color
variables of a light with color or color temperature as changed, as it learns
the light's capabilities again.

# <span style="color:#4ACBD6">Troubleshooting</span>

**`Driver Status` shows `Bind to an outlet or set the IP Address property`**:
the driver has neither an outlet binding nor a direct-mode configuration.

**Direct mode never connects**: verify the IP address, that TCP port 80 (KLAP)
or UDP port 9999 (legacy) is reachable from the controller, and, for devices on
KLAP firmware, that the credentials match the account the device is bound to in
the Tapo/Kasa app (auth mismatches are reported in the lua output window with
`Log Mode` set to `Print`).

**`Disconnected: ... device refused the handshake (HTTP 403) ...`**: The device
is rejecting the KLAP handshake before credentials are checked, which means it
is not accepting third-party connections. Work through these in order:

1. Make sure **Third-Party Compatibility** is on (Tapo app:
   `Me → Tapo Lab → Third-Party Compatibility`; Kasa app:
   `Settings → Third-Party Compatibility`). Firmware updates are known to turn
   it off.
1. If it is already on, turn it off and back on. A device added after the
   setting was turned on, or one that was just updated, may keep refusing
   connections until the setting is toggled, even though the app shows it on.
1. Run the [`Reconnect`](#reconnect) action. The driver also retries on every
   poll, so the status clears on its own once the device accepts the handshake.
1. If it still fails, power cycle the device to clear a handshake lockout, then
   run [`Reconnect`](#reconnect) again.

**A Kasa light strip shows the wrong brightness while an app effect runs**: the
strip reports the effect's brightness while a lighting effect is active; any
light command from Control4 stops the effect and takes over.

**Device is a Kasa plug or strip, not a light**: use the TP-Link Outlet driver
for the device and bind this driver to one of its outputs instead of using
direct mode.

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
from Finite Labs LLC.

<!-- #endif -->

# <span style="color:#4ACBD6">Support</span>

<!-- #ifdef DRIVERCENTRAL -->

If you have any questions or issues integrating this driver with Control4 or
your TP-Link device, you can contact us at
[driver-support@finitelabs.com](mailto:driver-support@finitelabs.com) or
call/text us at [+1 (949) 371-5805](tel:+19493715805).

<!-- #else -->

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/finitelabs/control4-tplink/issues/new

<a href="https://www.buymeacoffee.com/derek.miller" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>

<!-- #endif -->

<!-- #embed-changelog -->
