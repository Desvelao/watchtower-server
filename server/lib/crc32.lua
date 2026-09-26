-- Standard table-driven CRC-32 (the zip file format's checksum algorithm).
-- Shared by lib/zip_writer.lua and lib/zip_reader.lua so the table build +
-- core loop exist in exactly one place.
local bit = require("bit")

local CRC32_POLY = 0xEDB88320
local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(bit.rshift(c, 1), CRC32_POLY)
    else
      c = bit.rshift(c, 1)
    end
  end
  crc_table[i] = c
end

local function crc32(str)
  local crc = 0xFFFFFFFF
  for i = 1, #str do
    local byte = str:byte(i)
    crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, byte), 0xFF)])
  end
  local result = bit.bxor(crc, 0xFFFFFFFF)
  -- bit.bxor returns a signed 32-bit Lua number (range -2^31..2^31-1);
  -- normalize to the unsigned range so this compares correctly against a
  -- CRC read from bytes as an unsigned value (e.g. zip_reader.lua's u32).
  if result < 0 then
    result = result + 4294967296
  end
  return result
end

return { crc32 = crc32 }
