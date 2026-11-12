--- The light library's design rows and benign differences, as the v20261110 suites mark them with T.differs.
--- A row is a behavior the switch changes in the released driver, with a CHANGELOG line; a benign entry changes
--- nothing an integrator sees; a pending entry is a library bug its next round fixes.

--- @class LightRowStrings
--- @field ROWS table<string, string>
--- @field BENIGN table<string, string>
--- @field PENDING table<string, string>

--- @type LightRowStrings
return {
  ROWS = {
    START_TELL = "At each start and reconnect the light tells its capabilities, brightness and color, even unchanged.",
    DIFF = "A command for the level or color the proxy shows tells nothing.",
    GETLEVEL = "Get Light Level answers the level last told, during a ramp and a lapse too.",
    BUTTON_COLORS = "A button with no saved colors takes the setup's colors, then the standard defaults.",
    ON_COLOR_FADE = "An on from off fades the color from the one the light kept to its on color, over the on's time.",
    DTW_OFF = "An off under Dim-To-Warm fades the color all the way to the Dim color.",
    DTW_WHITE = "A Dim-To-Warm white is told at the point on the line of whites the light shows.",
    RAMP_FROM = "A ramp starts from where the light has got to.",
    STEP_PICK = "A scene step that sets level and color together is not a picked color.",
    HELD_PICK = "A color held for the next on stays the pick when another client turns the light on.",
    GATE_CMD = "A command during a keypad's 250 ms press wait leaves it; the hold starts if the button stays down.",
    HOLD_LET_GO = "A keypad hold let go inside the hold delay leaves a fade the light was already in running; "
      .. "it stops only a hold or a scene ramp.",
    LINK_PRESS = "A link press leaves a running scene until the hold starts or the click acts.",
    SCENE_UP = "Ramp Scene Up goes to full, not the on level.",
    HOLD_SCALED = "A hold's time is scaled to the distance left.",
    TOGGLE_HOLD = "Toggle's hold direction follows the last ramp: up after a ramp to off, otherwise down.",
    REBIND = "A rebind to another device shows the light offline until the new device reports.",
    GATE = "A keypad hold on a light that dims starts 250 ms after the press.",
    OFF_BEHIND = "tplink: an off waits behind a color still to go, which the light would drop with it.",
    READ_FIRST = "tplink: a Fades change to Light ends a running ramp once the light's own fades are read.",
    READ_BACK = "tplink: a command no poll has confirmed by its wait is read back once.",
    OFF_AT_ONCE = "tplink: an off at once tells CHANGED 0 with no CHANGING.",
    RECONNECT = "tplink: a reconnect tells ONLINE_CHANGED.",
    CARRIED_COLOR = "tplink: a color ramp a replacing command carries on is not told again; its end is.",
    KASA_HOLD = "tplink: a color for an off Kasa light is held for the next on, not sent.",
    DIM_OFF = "tplink: an off under Dim-To-Warm fades to its Dim color.",
    LEDS = "tplink: a button with no saved colors reports the setup's colors or the defaults, never blank.",
    STOP_STEP = "tplink: a stop of a driver-made fade sends one last step at where the fade has got to.",
    WALK = "tplink: a driver-made fade steps every 100 ms, and a step waiting behind one in flight is replaced by "
      .. "the newest.",
    KASA_MAX = "tplink: a Kasa light's longest fade is 60 s.",
  },
  BENIGN = {
    ORDER = "benign: tells and sends in one ms come in another order",
    STEP_TIMER = "benign: a scene step with nothing to wait on goes out on the step timer",
    RETELL = "benign: a color the proxy already shows is told again or not",
    PRECISION = "benign: a level estimated a few ms apart is told one level off",
    SCENEDTW = "benign: Stop Scene Ramp in a Dim-To-Warm step sends one command where the released driver sent "
      .. "two; the end state is the same",
    FOLLOWUP_PRESET = "benign: a follow-up naming another preset is sent again",
    PREON_MODE = "benign: the pre-on names the mode the light would pick",
    DTW_EST = "benign: the Dim-To-Warm estimate differs by 0.001 in x",
    FADING_COLOR = "benign: a step lighting a light still fading to off sends the fade's color again",
    RAMP_END = "benign: a color ramp's end goes out with the level",
    LANDING = "benign: a command lands a few hundred ms from where the wire's own landing would be",
    HELD_COLOR_STORE = "benign: a color held for the next on is kept through a restart by the proxy's color "
      .. "variables, not a stored key",
  },
  PENDING = {
    TOP_CLICK = "library round 4: a Top click from off ramps to the on mode's preset level when one is set",
  },
}
