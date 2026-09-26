-- Minimal ZIP writer: STORE method only (no compression). Deliberately not
-- a general-purpose zip library - hand-rolled the same way rule_source.lua
-- is, to avoid pulling in a zlib/libzip-backed Luarocks package (none is
-- installed today, and one would mean apk/Dockerfile changes) for what's a
-- small, well-defined binary format over small in-memory text files.
local bit = require("bit")
local crc32 = require("lib.crc32").crc32

local function le16(n)
  return string.char(bit.band(n, 0xFF), bit.band(bit.rshift(n, 8), 0xFF))
end

local function le32(n)
  return string.char(
    bit.band(n, 0xFF),
    bit.band(bit.rshift(n, 8), 0xFF),
    bit.band(bit.rshift(n, 16), 0xFF),
    bit.band(bit.rshift(n, 24), 0xFF)
  )
end

-- A fixed, valid MS-DOS date/time (1980-01-01 00:00:00) - exact
-- timestamps don't matter for exported rule files, and hardcoding avoids
-- needing DOS date/time encoding math.
local DOS_TIME = le16(0)
local DOS_DATE = le16(0x21)

-- `files` is an array of { name = "...", content = "..." }. Returns the
-- raw bytes of a valid .zip archive.
local function build(files)
  local local_parts = {}
  local central_parts = {}
  local offset = 0

  for _, file in ipairs(files) do
    local crc = crc32(file.content)
    local size = le32(#file.content)
    local name_len = le16(#file.name)

    local local_header = table.concat({
      le32(0x04034b50),
      le16(20), -- version needed
      le16(0), -- flags
      le16(0), -- compression method: store
      DOS_TIME,
      DOS_DATE,
      le32(crc),
      size, -- compressed size
      size, -- uncompressed size
      name_len,
      le16(0), -- extra field length
      file.name,
    })
    table.insert(local_parts, local_header)
    table.insert(local_parts, file.content)

    table.insert(
      central_parts,
      table.concat({
        le32(0x02014b50),
        le16(20), -- version made by
        le16(20), -- version needed
        le16(0), -- flags
        le16(0), -- compression method
        DOS_TIME,
        DOS_DATE,
        le32(crc),
        size,
        size,
        name_len,
        le16(0), -- extra field length
        le16(0), -- comment length
        le16(0), -- disk number start
        le16(0), -- internal attrs
        le32(0), -- external attrs
        le32(offset), -- local header offset
        file.name,
      })
    )

    offset = offset + #local_header + #file.content
  end

  local central_directory = table.concat(central_parts)
  local end_record = table.concat({
    le32(0x06054b50),
    le16(0), -- disk number
    le16(0), -- disk with central dir
    le16(#files), -- entries on this disk
    le16(#files), -- total entries
    le32(#central_directory),
    le32(offset), -- central dir offset
    le16(0), -- comment length
  })

  return table.concat(local_parts) .. central_directory .. end_record
end

return { build = build }
