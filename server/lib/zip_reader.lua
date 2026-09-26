-- Minimal ZIP reader: supports STORE (method 0) and DEFLATE (method 8) -
-- the two methods every common zip tool actually produces. DEFLATE is
-- decompressed via a small FFI binding directly to the system's zlib
-- (/usr/lib/libz.so.1, already present as an nginx/OpenResty runtime
-- dependency - confirmed present in this project's dev image), so this
-- needs no new Dockerfile/Luarocks dependency, unlike hand-rolling inflate
-- in pure Lua.
local ffi = require("ffi")
local bit = require("bit")
local crc32 = require("lib.crc32").crc32

ffi.cdef([[
typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;
typedef void* voidpf;
typedef voidpf (*alloc_func)(voidpf opaque, unsigned int items, unsigned int size);
typedef void (*free_func)(voidpf opaque, voidpf address);
typedef struct z_stream_s {
  const Bytef *next_in;
  uInt     avail_in;
  uLong    total_in;
  Bytef    *next_out;
  uInt     avail_out;
  uLong    total_out;
  const char *msg;
  void *state;
  alloc_func zalloc;
  free_func  zfree;
  voidpf     opaque;
  int     data_type;
  uLong   adler;
  uLong   reserved;
} z_stream;
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
]])

local zlib = ffi.load("/usr/lib/libz.so.1")

-- Zip entries in this codebase are always small YAML rule/policy/user/role
-- documents (or the .zip's own directory entries), never legitimately
-- anywhere near this large. `expected_size`/`uncompressed_size` below come
-- straight from the attacker-controlled zip's central directory, so they're
-- capped up front - both per-entry and summed across the whole archive -
-- before either is ever used to size an FFI allocation.
local MAX_ENTRY_UNCOMPRESSED_SIZE = 64 * 1024 * 1024 -- 64 MiB
local MAX_TOTAL_UNCOMPRESSED_SIZE = 256 * 1024 * 1024 -- 256 MiB

-- Raw DEFLATE (no zlib/gzip wrapper - that's what's inside a zip entry),
-- windowBits -15. `expected_size` is the entry's recorded uncompressed
-- size, so the output buffer is sized exactly (plus a small pad, just in
-- case) rather than growing it dynamically. Caller must have already
-- bounds-checked `expected_size` against MAX_ENTRY_UNCOMPRESSED_SIZE.
local function inflate_raw(data, expected_size)
  local strm = ffi.new("z_stream")
  ffi.fill(strm, ffi.sizeof(strm), 0)
  local ret = zlib.inflateInit2_(strm, -15, "1.2.11", ffi.sizeof(strm))
  if ret ~= 0 then
    return nil, "inflateInit2_ failed: " .. ret
  end

  local input = ffi.new("unsigned char[?]", #data, data)
  strm.next_in = input
  strm.avail_in = #data

  local out_size = expected_size + 64
  local output = ffi.new("unsigned char[?]", out_size)
  strm.next_out = output
  strm.avail_out = out_size

  ret = zlib.inflate(strm, 0)
  local produced = out_size - strm.avail_out
  zlib.inflateEnd(strm)

  if ret ~= 0 and ret ~= 1 then -- 1 = Z_STREAM_END, 0 = Z_OK
    return nil, "inflate failed: " .. ret
  end

  return ffi.string(output, produced)
end

local function u16(data, pos)
  local a, b = data:byte(pos, pos + 1)
  return a + b * 256
end

local function u32(data, pos)
  local a, b, c, d = data:byte(pos, pos + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local EOCD_SIG = "PK\5\6"
local CENTRAL_SIG = "PK\1\2"
local LOCAL_SIG = "PK\3\4"

local function find_eocd(data)
  -- The end-of-central-directory record is the last thing in the file,
  -- but can be followed by a (rare, usually empty) comment - search
  -- backward for its signature instead of assuming it's the last 22 bytes.
  local max_back = math.min(#data, 65557) -- 22 + max 65535-byte comment
  for pos = #data - 21, #data - max_back + 1, -1 do
    if pos >= 1 and data:sub(pos, pos + 3) == EOCD_SIG then
      return pos
    end
  end
  return nil
end

-- Returns an array of { name, content }, or nil, err.
local function read(data)
  local eocd_pos = find_eocd(data)
  if not eocd_pos then
    return nil, "Not a valid zip file (no end-of-central-directory record found)"
  end

  local total_entries = u16(data, eocd_pos + 10)
  local central_dir_offset = u32(data, eocd_pos + 16)

  local entries = {}
  local total_uncompressed_size = 0
  local pos = central_dir_offset + 1 -- Lua strings are 1-indexed
  for _ = 1, total_entries do
    if data:sub(pos, pos + 3) ~= CENTRAL_SIG then
      return nil, "Corrupt zip: central directory entry signature mismatch"
    end

    local method = u16(data, pos + 10)
    local crc = u32(data, pos + 16)
    local compressed_size = u32(data, pos + 20)
    local uncompressed_size = u32(data, pos + 24)
    local name_len = u16(data, pos + 28)
    local extra_len = u16(data, pos + 30)
    local comment_len = u16(data, pos + 32)
    local local_header_offset = u32(data, pos + 42)
    local name = data:sub(pos + 46, pos + 46 + name_len - 1)

    -- Declared sizes come straight from the (attacker-controlled) zip's
    -- central directory - reject an oversized declaration here, before
    -- it's ever used to size an FFI allocation in inflate_raw.
    if uncompressed_size > MAX_ENTRY_UNCOMPRESSED_SIZE then
      return nil, "Zip entry " .. name .. " declares an uncompressed size (" ..
        uncompressed_size .. " bytes) exceeding the " .. MAX_ENTRY_UNCOMPRESSED_SIZE .. "-byte limit"
    end
    total_uncompressed_size = total_uncompressed_size + uncompressed_size
    if total_uncompressed_size > MAX_TOTAL_UNCOMPRESSED_SIZE then
      return nil, "Zip file's total declared uncompressed size exceeds the " ..
        MAX_TOTAL_UNCOMPRESSED_SIZE .. "-byte limit"
    end

    table.insert(entries, {
      name = name,
      method = method,
      crc = crc,
      compressed_size = compressed_size,
      uncompressed_size = uncompressed_size,
      local_header_offset = local_header_offset,
    })

    pos = pos + 46 + name_len + extra_len + comment_len
  end

  local files = {}
  for _, entry in ipairs(entries) do
    -- Directory entries (name ends in "/") have no data - skip them,
    -- they're not rule files.
    if entry.name:sub(-1) ~= "/" then
      local lp = entry.local_header_offset + 1
      if data:sub(lp, lp + 3) ~= LOCAL_SIG then
        return nil, "Corrupt zip: local file header signature mismatch for " .. entry.name
      end
      local local_name_len = u16(data, lp + 26)
      local local_extra_len = u16(data, lp + 28)
      local data_start = lp + 30 + local_name_len + local_extra_len
      local raw = data:sub(data_start, data_start + entry.compressed_size - 1)

      local content, err
      if entry.method == 0 then
        content = raw
      elseif entry.method == 8 then
        content, err = inflate_raw(raw, entry.uncompressed_size)
        if not content then
          return nil, "Failed to decompress " .. entry.name .. ": " .. err
        end
      else
        return nil, "Unsupported compression method (" .. entry.method .. ") for " .. entry.name
      end

      if crc32(content) ~= entry.crc then
        return nil, "Checksum mismatch for " .. entry.name .. " (corrupt zip?)"
      end

      table.insert(files, { name = entry.name, content = content })
    end
  end

  return files
end

return { read = read }
