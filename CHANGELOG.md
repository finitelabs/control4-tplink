# <span style="color:#4ACBD6">Changelog</span>

<!-- prettier-ignore-start -->
[//]: # "## v[Version] - YYY-MM-DD"
[//]: # "### Added"
[//]: # "- Added"
[//]: # "### Fixed"
[//]: # "- Fixed"
[//]: # "### Changed"
[//]: # "- Changed"
[//]: # "### Removed"
[//]: # "- Removed"
<!-- prettier-ignore-end -->

## Unreleased

### Added

- Initial release: local control of TP-Link Kasa power strips and smart plugs on
  KLAP firmware (KLAP v2 transport, legacy IOT command schema).
- Legacy port 9999 transport with automatic protocol detection, covering devices
  still on original Kasa firmware (no credentials required) and surviving
  TP-Link's forced migration to KLAP.
- Relay bindings, events, variables, and programming commands per output.
- Per-outlet real-time energy monitoring with configurable poll rates.
