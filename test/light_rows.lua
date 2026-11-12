--- The light library's design rows and benign differences, as the v20261110 suites mark them with T.differs.
--- A row is a behavior the switch changes in the released driver; a benign entry changes nothing an integrator
--- sees.

--- @class LightRowStrings
--- @field ROWS table<string, string>
--- @field BENIGN table<string, string>

--- @type LightRowStrings
return {
  ROWS = {
    START_TELL = "At each start and reconnect the light tells its capabilities, brightness and color, even unchanged.",
    DIFF = "A command for the level or color the proxy shows tells nothing.",
    GETLEVEL = "Get Light Level answers the level last told, during a ramp and a lapse too.",
    BUTTON_COLORS = "A button with no saved colors takes the setup's colors, then the standard defaults.",
    ON_COLOR_FADE = "An on from off fades the color from the one the light kept to its on color, over the on's time.",
    DTW_WHITE = "A Dim-To-Warm white is told at the point on the line of whites the light shows.",
    RAMP_FROM = "A ramp starts from where the light has got to.",
    STEP_PICK = "A scene step that sets level and color together is not a picked color.",
    HELD_PICK = "A color held for the next on stays the pick when another client turns the light on.",
    GATE_CMD = "A command during a keypad's 250 ms press wait leaves it; the hold starts if the button stays down.",
    SCENE_UP = "Ramp Scene Up goes to full, not the on level.",
    HOLD_SCALED = "A hold's time is scaled to the distance left.",
    GATE = "A keypad hold on a light that dims starts 250 ms after the press.",
    STOP_LOWEST = "A stop just after an on from off holds the light at its lowest level, lit.",
    SCENE_STOP = "Stop Scene Ramp lets a scene step's fade finish; it stops a Ramp Scene Up or Down where it has got "
      .. "to.",
    TOGGLE_FADE = "A Toggle click on a light still fading up from off turns it on to its Default On level.",
    DTW_LINE = "Dim-To-Warm mixes in a straight line between its two colors, whites included.",
    TOGGLE_HOLD_FADE = "A Toggle hold during the light's own fade up from off goes up.",
    CLICK_FADE = "A keypad click on a light that dims fades over the click rate.",
    ON_AGAIN = "A light turned on again before its fade to off has ended keeps the color it had.",
    ECHOES = "Setting echoes answer setting commands only, never a start.",
    SWITCH_AT_ONCE = "A light that doesn't dim switches and is told at once.",
    OFF_BEHIND = "tplink: an off waits behind a color still to go, which the light would drop with it.",
    READ_FIRST = "tplink: a Fades change to Light ends a running ramp once the light's own fades are read.",
    READ_BACK = "tplink: a command no poll has confirmed by its wait is read back once.",
    OFF_AT_ONCE = "tplink: an off at once tells CHANGED 0 with no CHANGING.",
    RECONNECT = "tplink: a reconnect tells ONLINE_CHANGED.",
    CARRIED_COLOR = "tplink: a color ramp a replacing command carries on is not told again; its end is.",
    OFF_HOLD = "tplink: a color for a light that's off is held for the next on, not sent.",
    DIM_OFF = "tplink: an off under Dim-To-Warm fades to its Dim color.",
    LEDS = "tplink: a button with no saved colors reports the setup's colors or the defaults, never blank.",
    STOP_STEP = "tplink: a stop of a driver-made fade sends one last step at where the fade has got to.",
    WALK = "tplink: a driver-made fade steps every 100 ms, and a step waiting behind one in flight is replaced by "
      .. "the newest.",
    KASA_MAX = "tplink: a Kasa light's longest fade is 60 s.",
    WALK_DAY = "tplink: a light whose fades the driver makes offers rates up to a day.",
  },
  BENIGN = {
    ORDER = "benign: tells and sends in one ms come in another order",
    RETELL = "benign: a color the proxy already shows is told again or not",
    PRECISION = "benign: a level estimated a few ms apart is told one level off",
    RAMP_END = "benign: a color ramp's end goes out with the level",
    SAME_LEVEL_SENT = "benign: an unchanged level is sent to the device",
    DIAG = "benign until its follow-up: a proxy read error is logged, not captured for Cloud Monitoring",
    SETUP_FILL = "benign: an install that never stored them takes them from the proxy's setup",
    OUTLET_MODE = "benign: tplink: a light on an outlet is sent the color mode it is picked in, as a direct light is",
  },
}
