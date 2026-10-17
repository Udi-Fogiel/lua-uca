-- implicit primary weights for the characters without mappings in the root
-- collation, computed as in ICU (collationbasedatabuilder.cpp, collation.cpp):
-- Han in the order of the [Unified_Ideograph] ranges of FractionalUCA.txt,
-- other code points by their value
local M = {}

-- written without the integer operators of Lua 5.3, for LuaJIT
local floor = math.floor
local byte2, byte3 = 0x10000, 0x100
local byte1 = 0x1000000

-- add offset to a three-byte primary weight, the second and third bytes use
-- the values 02..FF (ICU's incThreeBytePrimaryByOffset, not compressible)
local function inc_primary(base, offset)
  offset = offset + floor(base / byte3) % 256 - 2
  local primary = ((offset % 254) + 2) * byte3
  offset = floor(offset / 254)
  offset = offset + floor(base / byte2) % 256 - 2
  primary = primary + ((offset % 254) + 2) * byte2
  offset = floor(offset / 254)
  return primary + (floor(base / byte1) + offset) * byte1
end

-- prepare the Han ranges: {first, last, primary of first}, sorted by code
-- point; the ranges get primaries with step 2 below the unassigned lead byte
function M.han_ranges(ranges, unassigned_lead)
  local count = 0
  for _, range in ipairs(ranges) do count = count + range[2] - range[1] + 1 end
  local step = 2
  local han = count * step + step + 2
  local per_lead_byte = 254 * 254
  local lead_bytes = floor((han + per_lead_byte - 1) / per_lead_byte)
  local primary = (unassigned_lead - lead_bytes) * byte1 + 0x020200
  local prepared = {first = primary, count = count}
  for _, range in ipairs(ranges) do
    prepared[#prepared + 1] = {range[1], range[2], primary}
    primary = inc_primary(primary, (range[2] - range[1] + 1) * step)
  end
  table.sort(prepared, function(a, b) return a[1] < b[1] end)
  return prepared
end

-- the number of three-byte steps from the first Han primary to the three
-- bytes of primary
local function han_offset(primary, first)
  local b1, b2, b3 = floor(primary / byte1), floor(primary / byte2) % 256, floor(primary / byte3) % 256
  local f1, f2, f3 = floor(first / byte1), floor(first / byte2) % 256, floor(first / byte3) % 256
  return ((b1 - f1) * 254 + (b2 - f2)) * 254 + (b3 - f3)
end

-- the Han primaries before and after a primary weight (nil when there is
-- none); the Han primaries are at the even offsets from the first one
function M.han_neighbors(primary, prepared)
  local first, last_offset = prepared.first, 2 * (prepared.count - 1)
  if primary < first then return nil, first end
  local offset = han_offset(primary, first)
  local exact = primary % 256 == 0 and offset % 2 == 0
  local next_offset = offset % 2 == 0 and offset + 2 or offset + 1
  local previous_offset
  if exact then
    previous_offset = offset - 2
  elseif offset % 2 == 0 then
    previous_offset = offset
  else
    previous_offset = offset - 1
  end
  local previous, nextone
  if previous_offset >= 0 and previous_offset <= last_offset then previous = inc_primary(first, previous_offset) end
  if previous_offset > last_offset then previous = inc_primary(first, last_offset) end
  if next_offset <= last_offset then nextone = inc_primary(first, next_offset) end
  return previous, nextone
end

-- the primaries of unassigned code points before and after a primary weight
-- with the unassigned lead byte
function M.unassigned_neighbors(primary, unassigned_lead)
  local b2, b3, b4 = floor(primary / byte2) % 256, floor(primary / byte3) % 256, primary % 256
  local c = ((b2 - 4) * 254 + (b3 - 2)) * 18 + floor((b4 - 2) / 14)
  local exact = (b4 - 2) % 14 == 0 and b4 >= 2
  local previous_c = exact and c - 1 or c
  local next_c = c + 1
  local previous, nextone
  if previous_c >= 0 then previous = M.unassigned_primary(previous_c - 1, unassigned_lead) end
  if next_c <= 0x110000 then nextone = M.unassigned_primary(next_c - 1, unassigned_lead) end
  return previous, nextone
end

-- the primary of a Han character, or nil
function M.han_primary(codepoint, prepared)
  local low, high = 1, #prepared
  while low <= high do
    local mid = floor((low + high) / 2)
    local range = prepared[mid]
    if codepoint < range[1] then
      high = mid - 1
    elseif codepoint > range[2] then
      low = mid + 1
    else
      return inc_primary(range[3], (codepoint - range[1]) * 2)
    end
  end
end

-- the primary of an unassigned code point (ICU's
-- unassignedPrimaryFromCodePoint), four bytes
function M.unassigned_primary(codepoint, unassigned_lead)
  local c = codepoint + 1
  local primary = 2 + (c % 18) * 14
  c = floor(c / 18)
  primary = primary + (2 + (c % 254)) * byte3
  c = floor(c / 254)
  primary = primary + (4 + (c % 251)) * byte2
  return primary + unassigned_lead * byte1
end

return M
