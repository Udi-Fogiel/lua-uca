-- make the root collation table from CLDR's FractionalUCA.txt
-- texlua tools/make_root.lua table > src/lua-uca/lua-uca-root.lua
-- texlua tools/make_root.lua info > src/lua-uca/lua-uca-root-info.lua
-- texlua tools/make_root.lua radical > src/lua-uca/lua-uca-han-radical.lua
-- the fractional weights are padded to integers: primaries to 32 bits,
-- secondaries and tertiaries to 16 bits; the case bits (the top two bits of
-- the tertiary weight) are kept in the `case` field
local collation = require "tools.collation"
local serpent = require "tools.serpent"
local implicit = dofile("src/lua-uca/lua-uca-implicit.lua")

local mode = arg[1]

local function bytes(field)
  local t = {}
  for byte in field:gmatch("%x%x") do t[#t + 1] = tonumber(byte, 16) end
  return t
end

local function pad(field, length)
  local value = 0
  for i, byte in ipairs(bytes(field)) do value = value | (byte << (8 * (length - i))) end
  return value
end

-- one collation element from its three fields
local function element(primary, secondary, tertiary)
  local ce = {pad(primary, 4), pad(secondary, 2), 0}
  local t = bytes(tertiary)
  if t[1] then
    local case = t[1] >> 6
    ce[3] = ((t[1] & 0x3F) << 8) | (t[2] or 0)
    if case ~= 0 then ce.case = case end
  end
  return ce
end

local function codepoints(s)
  local t = {}
  for hex in s:gmatch("%x+") do t[#t + 1] = tonumber(hex, 16) end
  return t
end

local mappings, order = {}, {}
local group_lines = {}
local radical_ranges = {}
local version, variable_top, han_ranges, first_trail_byte
-- the lead bytes of compressible primaries ([top_byte .. COMPRESS])
local compressible = {}
local anchors = {}
for line in io.lines("data/FractionalUCA.txt") do
  local content = line:gsub("%s*#.*$", "")
  if content:match("^%[") then
    version = version or content:match("^%[UCA version = ([%d%.]+)%]")
    local compress = content:match("^%[top_byte%s+(%x%x)%s.-COMPRESS")
    if compress then compressible[#compressible + 1] = tonumber(compress, 16) end
    local trail = content:match("^%[fixed first trail byte (%x%x)%]")
    if trail then first_trail_byte = tonumber(trail, 16) end
    local top = content:match("^%[variable top = ([%x ]+)%]")
    if top then variable_top = pad(top, 4) end
    -- the radical-stroke order: the Han characters and ranges after the colon
    local radical = line:match("^%[radical [^:]*:(.*)%]%s*$")
    if radical then
      local list = {}
      for _, code in utf8.codes(radical) do list[#list + 1] = code end
      local i = 1
      while list[i] do
        local first, last = list[i], list[i]
        if list[i + 1] == 0x2D then last, i = list[i + 2], i + 2 end
        local previous = radical_ranges[#radical_ranges]
        if previous and previous[2] + 1 == first then
          previous[2] = last
        else
          radical_ranges[#radical_ranges + 1] = {first, last}
        end
        i = i + 1
      end
    end
    local ranges = content:match("^%[Unified_Ideograph ([^%]]+)%]")
    if ranges then
      han_ranges = {}
      for first, last in ranges:gmatch("(%x+)%.?%.?(%x*)") do
        first = tonumber(first, 16)
        han_ranges[#han_ranges + 1] = {first, last ~= "" and tonumber(last, 16) or first}
      end
    end
    local name, ce = content:match("^%[([%a %-]-) %[([^%]]*)%]%]$")
    if name and (name:match("^first ") or name:match("^last ")) then
      local fields = {}
      for field in (ce .. ","):gmatch("([^,]*),") do fields[#fields + 1] = field end
      -- X stands for any weight
      for i, field in ipairs(fields) do if field:match("X") then fields[i] = "" end end
      anchors[name] = element(fields[1] or "", fields[2] or "", fields[3] or "")
    end
  else
    -- the first primaries of the special groups
    local group = line:match("#%s*(%u+) first primary")
    if group and line:match("^FDD1 ") then
      group_lines[group] = {content = content, new_lead_byte = line:match("starts new lead byte") ~= nil}
    end
    local prefix, key, ces = content:match("^([%x ]-)%s*|%s*([%x ]+);%s*(.+)$")
    if not prefix then key, ces = content:match("^([%x ]+);%s*(.+)$") end
    if key then
      local value = {}
      for ce in ces:gmatch("%[([^%]]*)%]") do
        local fields = {}
        for field in (ce .. ","):gmatch("([^,]*),") do fields[#fields + 1] = field:match("^%s*(.-)%s*$") end
        local reference = fields[1]:match("^U%+(%x+)$")
        if reference then
          value[#value + 1] = {reference = tonumber(reference, 16), secondary = fields[2], tertiary = fields[3]}
        else
          value[#value + 1] = element(fields[1], fields[2] or "", fields[3] or "")
        end
      end
      local cps = codepoints(key)
      local entry = {key = cps, value = value, prefix = prefix and codepoints(prefix)}
      local id = table.concat(cps, " ")
      if prefix then id = table.concat(entry.prefix, " ") .. " | " .. id end
      mappings[id] = entry
      order[#order + 1] = entry
    end
  end
end

local unassigned_lead = mappings[string.format("%d %d", 0xFDD1, 0xFDD0)].value[1][1] >> 24
local merge_separator = mappings[tostring(0xFFFE)].value[1][1]
local prepared = implicit.han_ranges(han_ranges, unassigned_lead)

-- the collation element of a referenced character: its mapping, or its
-- implicit Han weight
local function referenced(codepoint)
  local entry = mappings[tostring(codepoint)]
  -- a Han character can refer to itself ([U+FA0E] for U+FA0E): its
  -- implicit weight
  if entry and entry.value[1].reference ~= codepoint then
    assert(#entry.value == 1 and not entry.value[1].reference, "reference to a character with more than one collation element")
    return entry.value[1]
  end
  local primary = assert(implicit.han_primary(codepoint, prepared), "reference to a character without weights")
  -- han: the primary is that of a Han character, in the order of han_order
  return {primary, 0x0500, 0x0500, han = codepoint}
end

local function resolve(value)
  for i, ce in ipairs(value) do
    if ce.reference then
      local base = referenced(ce.reference)
      local new
      if not ce.secondary then
        -- [U+4E0D]: the whole collation element
        new = {base[1], base[2], base[3], case = base.case}
      elseif not ce.tertiary then
        -- [U+4E36, 10]: primary and secondary, a new tertiary
        new = element("", "", ce.secondary)
        new[1], new[2] = base[1], base[2]
      else
        -- [U+4E36, 70, 20]: the primary, new secondary and tertiary
        new = element("", ce.secondary, ce.tertiary)
        new[1] = base[1]
      end
      new.han = base.han
      value[i] = new
    end
  end
  return value
end

-- the variable top for each value of max_variable: the last primary
-- before the next group; a group that starts a new lead byte starts at that
-- byte, otherwise at the top 16 bits of its first primary (as ICU's
-- scriptStarts)
local function group_start(name)
  local group = assert(group_lines[name], "no first primary for " .. name)
  local primary = mappings[table.concat(codepoints(group.content:match("^([%x ]+);")), " ")].value[1][1]
  if group.new_lead_byte then return primary & 0xFF000000 end
  return primary & 0xFFFF0000
end
local variable_tops = {
  space = group_start("PUNCTUATION") - 1,
  punct = group_start("SYMBOL") - 1,
  symbol = group_start("CURRENCY") - 1,
  currency = group_start("DIGIT") - 1,
}
assert(variable_tops.punct == variable_top, "the variable top is not the end of punct")

-- the DUCET's variable characters (allkeys.txt) as a variable top: the
-- highest root primary of a character that is variable in the DUCET; the
-- order is the same, so the non-variable ones are all above it
local function ducet_variable_top()
  local ducet = collation.new()
  local file = assert(io.open("data/allkeys.txt"))
  ducet:load_ducet(file:read("a"))
  file:close()
  local top, lowest_other = 0, math.huge
  for codepoint, node in pairs(ducet.keys) do
    local entry = mappings[tostring(codepoint)]
    local ce = node.value and node.value[1]
    if entry and ce and ce[1] ~= 0 and not entry.value[1].reference then
      local primary = entry.value[1][1]
      if ce.type == "*" then
        top = math.max(top, primary)
      elseif primary > merge_separator then
        lowest_other = math.min(lowest_other, primary)
      end
    end
  end
  assert(top < lowest_other, "the DUCET's variable characters are not a range of root primaries")
  return top
end

if mode == "radical" then
  -- the same characters as the Unified_Ideograph ranges (as ICU checks)
  local count, radical_count = 0, 0
  for _, range in ipairs(han_ranges) do count = count + range[2] - range[1] + 1 end
  for _, range in ipairs(radical_ranges) do radical_count = radical_count + range[2] - range[1] + 1 end
  assert(count == radical_count, "the [radical] lines do not have the Unified_Ideograph characters")
  local out = {}
  for i, range in ipairs(radical_ranges) do
    out[#out + 1] = string.format("0x%X,0x%X,", range[1], range[2])
    if i % 6 == 0 then out[#out + 1] = "\n" end
  end
  print("-- generated by tools/make_root.lua from FractionalUCA.txt (UCA " .. version .. ")")
  print("-- the Han ranges in radical-stroke order, as first, last pairs")
  print("return {")
  print(table.concat(out))
  print("}")
  return
end

if mode == "info" then
  variable_tops.ducet = ducet_variable_top()
  -- the primaries of the FDD0 and FDD1 contractions: boundaries of the groups
  -- and reserved ranges, as weights in use for tailoring
  local boundaries, seen = {}, {}
  for _, entry in ipairs(order) do
    local first = entry.key[1]
    local primary = entry.value[1] and entry.value[1][1]
    if (first == 0xFDD0 or first == 0xFDD1) and primary and primary ~= 0 and not seen[primary] then
      seen[primary] = true
      boundaries[#boundaries + 1] = primary
    end
  end
  table.sort(boundaries)
  -- the collation elements of the FDD0 contractions, for the root elements
  local root_elements = {}
  for _, entry in ipairs(order) do
    if entry.key[1] == 0xFDD0 then
      for _, ce in ipairs(resolve(entry.value)) do root_elements[#root_elements + 1] = ce end
    end
  end
  local info = {
    root_elements = root_elements,
    boundaries = boundaries,
    -- the trailing weights start with this lead byte
    first_trail_byte = first_trail_byte,
    compressible = compressible,
    version = version,
    variable_top = variable_top,
    variable_tops = variable_tops,
    merge_separator = merge_separator,
    unassigned_lead = unassigned_lead,
    common_secondary = 0x0500,
    common_tertiary = 0x0500,
    han_ranges = han_ranges,
    anchors = anchors,
  }
  print("-- generated by tools/make_root.lua from FractionalUCA.txt (UCA " .. version .. ")")
  print(serpent.dump(info))
  return
end

local root = collation.new()
for _, entry in ipairs(order) do
  local first = entry.key[1]
  -- the FDD1 contractions (the boundaries of the groups and scripts) are
  -- mappings too, as in ICU (genuca.cpp, collationbasedatabuilder.cpp); FDD1
  -- FDD0 maps to ICU's first unassigned primary (lead byte, 04 02); the FDD0
  -- ones (reserved ranges, the numeric lead byte, homeless collation
  -- elements) are only root elements (in the info)
  if first ~= 0xFDD0 then
    local value = resolve(entry.value)
    if first == 0xFDD1 and entry.key[2] == 0xFDD0 then
      value = {{unassigned_lead * 0x1000000 + 0x040200, 0x0500, 0x0500}}
    end
    if entry.prefix then
      -- a prefix mapping p|x: the mapping of x after p, in the prefixes of
      -- x (the preceding code points in reverse)
      local x = root.keys[entry.key[1]]
      if not x then
        x = {}
        root.keys[entry.key[1]] = x
      end
      x.prefixes = x.prefixes or {}
      local map, node = x.prefixes
      for i = #entry.prefix, 1, -1 do
        local c = entry.prefix[i]
        node = map[c] or {}
        map[c] = node
        if i > 1 then
          node.more = node.more or {}
          map = node.more
        end
      end
      assert(#entry.key == 1, "prefix mapping with a contraction")
      node.entry = {value = value}
    else
      root:update_keys(entry.key, value)
    end
  end
end

print("-- generated by tools/make_root.lua from FractionalUCA.txt (UCA " .. version .. ")")
print(serpent.dump(root.keys))
