--- HSV to normalized RGB and back, as TP-Link lights name a color in hue and
--- saturation. C4:ColorHSVtoRGB and C4:ColorRGBtoHSV work on the 0-255 RGB
--- scale.

local Hsv = {}

--- HSV (h: 0-360, s: 0-100, v: 0-100) to normalized RGB (each 0-1).
--- @param h number?
--- @param s number?
--- @param v number?
--- @return number r
--- @return number g
--- @return number b
function Hsv.toRGB(h, s, v)
  local r, g, b = C4:ColorHSVtoRGB(h or 0, s or 0, v or 0)
  return (r or 0) / 255, (g or 0) / 255, (b or 0) / 255
end

--- Normalized RGB (0-1) to HSV (h: 0-360, s: 0-100, v: 0-100).
--- @param r number?
--- @param g number?
--- @param b number?
--- @return number h
--- @return number s
--- @return number v
function Hsv.fromRGB(r, g, b)
  return C4:ColorRGBtoHSV((r or 0) * 255, (g or 0) * 255, (b or 0) * 255)
end

return Hsv
