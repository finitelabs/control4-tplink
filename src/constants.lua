--- Constants used throughout the TP-Link Kasa driver.

return {
  --- Constant for showing a property in the UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Constant for hiding a property in the UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- Placeholder for dynamic list properties when nothing is selected.
  --- @type string
  SELECT_OPTION = "(Select)",

  --- Placeholder for "none" in dynamic lists.
  --- @type string
  NONE_OPTION = "None",

  --- Log level constants.
  --- @type table<string, string>
  LOG_LEVELS = {
    FATAL = "0 - Fatal",
    ERROR = "1 - Error",
    WARNING = "2 - Warning",
    INFO = "3 - Info",
    DEBUG = "4 - Debug",
    TRACE = "5 - Trace",
    ULTRA = "6 - Ultra",
  },

  --- Log mode constants.
  --- @type table<string, string>
  LOG_MODES = {
    OFF = "Off",
    PRINT = "Print",
    LOG = "Log",
    PRINT_AND_LOG = "Print and Log",
  },

  --- Maximum number of outputs supported (HS300 has 6).
  --- @type number
  MAX_OUTPUTS = 6,

  --- Event ID offset for "Output N Turned Off" events ("Turned On" events use the output number itself).
  --- @type number
  EVENT_OFF_OFFSET = 50,

  --- Event ID fired when the device connection is established.
  --- @type number
  EVENT_CONNECTED = 100,

  --- Event ID fired when the device connection is lost.
  --- @type number
  EVENT_DISCONNECTED = 101,

  --- Binding ID of the relay connection for output 1 (output N is RELAY_BINDING_BASE + N).
  --- @type number
  RELAY_BINDING_BASE = 100,
}
