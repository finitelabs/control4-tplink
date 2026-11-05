--- Constants used throughout the TP-Link Kasa driver.

return {
  --- Constant for showing a property in the UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Constant for hiding a property in the UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- Maximum number of outputs supported (HS300 has 6).
  --- @type number
  MAX_OUTPUTS = 6,

  --- Event ID offset for "Output N Turned Off" events ("Turned On" events use the output number itself).
  --- @type number
  EVENT_OFF_OFFSET = 50,

  --- Event ID offset for "Output N In Use" events.
  --- @type number
  EVENT_IN_USE_OFFSET = 20,

  --- Event ID offset for "Output N Idle" events.
  --- @type number
  EVENT_IDLE_OFFSET = 30,

  --- Event ID fired when the device connection is established.
  --- @type number
  EVENT_CONNECTED = 100,

  --- Event ID fired when the device connection is lost.
  --- @type number
  EVENT_DISCONNECTED = 101,

  --- Constant for virtual button identifiers (light_v2 BUTTON_ACTION).
  --- @type table<string, number>
  ButtonIds = {
    TOP = 0,
    BOTTOM = 1,
    TOGGLE = 2,
  },

  --- Constant for button action types (light_v2 BUTTON_ACTION).
  --- @type table<string, number>
  ButtonActions = {
    RELEASE_HOLD = 0,
    PRESS = 1,
    RELEASE_CLICK = 2,
  },

  --- Color modes shared across the TPLINK_LIGHT binding protocol between
  --- tplink_outlet (state provider) and tplink_light (light_v2 proxy).
  --- @type table<string, number>
  LightColorMode = {
    COLOR_MODE_UNKNOWN = 0,
    COLOR_MODE_ON_OFF = 1,
    COLOR_MODE_LEGACY_BRIGHTNESS = 2,
    COLOR_MODE_BRIGHTNESS = 3,
    COLOR_MODE_WHITE = 4,
    COLOR_MODE_COLOR_TEMPERATURE = 5,
    COLOR_MODE_COLD_WARM_WHITE = 6,
    COLOR_MODE_RGB = 7,
    COLOR_MODE_RGB_WHITE = 8,
    COLOR_MODE_RGB_COLOR_TEMPERATURE = 9,
    COLOR_MODE_RGB_COLD_WARM_WHITE = 10,
  },
}
