--- The light library's design rows that test_light_upgrade marks with T.differs, where an update from
--- v20261110 shows a behavior the switch changed.

--- @class LightRowStrings
--- @field ROWS table<string, string>

--- @type LightRowStrings
return {
  ROWS = {
    START_TELL = "At each start and reconnect the light tells its capabilities, brightness and color, even unchanged.",
    LEDS = "tplink: a button with no saved colors reports the setup's colors or the defaults, never blank.",
    WALK_MIN_MAX = "tplink: a driver-made fade between off and on stays on the Min to Max line and goes dark only at "
      .. "its end.",
  },
}
