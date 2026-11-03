--- The rolling XOR autokey cipher of TP-Link's legacy Kasa protocol (initial
--- key 171): each ciphertext byte becomes the key for the next byte.

--- LuaJIT bit library (available in the DriverWorks runtime).
local bit = require("bit")

local M = {}

--- Scrambles plaintext with the Kasa rolling XOR cipher.
--- @param plaintext string
--- @return string
function M.scramble(plaintext)
  local key = 171
  local out = {}
  for i = 1, #plaintext do
    key = bit.bxor(key, plaintext:byte(i))
    out[i] = string.char(key)
  end
  return table.concat(out)
end

--- Unscrambles a Kasa rolling-XOR ciphertext.
--- @param data string
--- @return string
function M.unscramble(data)
  local key = 171
  local out = {}
  for i = 1, #data do
    local byte = data:byte(i)
    out[i] = string.char(bit.bxor(key, byte))
    key = byte
  end
  return table.concat(out)
end

return M
