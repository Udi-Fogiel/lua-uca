-- make the table of primary weight ranges of the reordering groups (the
-- special groups and the scripts) from the boundaries in FractionalUCA.txt:
-- the FDD1 contractions map to the first primary of each group (CLDR 27 and
-- later); the FDD0 ones mark the reserved ranges; the names come from
-- Scripts.txt and PropertyValueAliases.txt (ISO 15924 codes), the special
-- groups from UnicodeData.txt (the General_Category of the character after
-- FDD1)
local serpent = require "tools.serpent"

local function read_ranges(filename, fn)
  for line in io.lines("data/" .. filename) do
    local first, last, rest = line:match("^(%x+)%.?%.?(%x*)%s*;%s*([^#]-)%s*#")
    if first then
      first = tonumber(first, 16)
      last = last ~= "" and tonumber(last, 16) or first
      fn(first, last, rest)
    end
  end
end

-- ISO 15924 codes of the scripts
local codes = {}
for line in io.lines("data/PropertyValueAliases.txt") do
  local code, name = line:match("^sc%s*;%s*(%S+)%s*;%s*(%S+)")
  if code then codes[name] = code end
end

local scripts = {}
read_ranges("Scripts.txt", function(first, last, script)
  if not codes[script] then error("no ISO 15924 code for script " .. script) end
  for codepoint = first, last do scripts[codepoint] = script end
end)

local categories = {}
for line in io.lines("data/UnicodeData.txt") do
  local codepoint, category = line:match("^(%x+);[^;]*;([^;]*);")
  if codepoint then categories[tonumber(codepoint, 16)] = category end
end

-- the special groups by the General_Category of their character (UTS #35)
local special = {space = true, punct = true, symbol = true, currency = true, digits = true}
local function special_group(category)
  -- characters in the ranges of UnicodeData.txt (Han, ...) are letters
  if not category then return nil end
  if category:match("^Z") then return "space" end
  if category:match("^P") then return "punct" end
  if category == "Sc" then return "currency" end
  if category:match("^S") then return "symbol" end
  if category == "Nd" then return "digits" end
end

local aliases = {
  -- CLDR's reorder code
  digits = {"digit"},
  -- names from the earlier, block based, table
  Katakana = {"hrkt", "katakana or hiragana"},
  Han = {"cjk"},
  Meetei_Mayek = {"meetei"},
  Syloti_Nagri = {"syloti"},
  Tai_Le = {"taile"},
  New_Tai_Lue = {"tailue"},
  Phags_Pa = {"phags-pa"},
  Cypriot = {"cypriot syllabary"},
}

local function names_of(name)
  local list = {}
  if not special[name] then
    list[1] = codes[name]:lower()
  end
  for _, alias in ipairs(aliases[name] or {}) do list[#list + 1] = alias end
  return (name:lower():gsub("_", " ")), list
end

local function bytes_to_primary(field)
  local value, i = 0, 0
  for byte in field:gmatch("%x%x") do
    value = value | (tonumber(byte, 16) << (8 * (3 - i)))
    i = i + 1
  end
  return value
end

-- the boundaries: {start, name}; a group that starts a new lead byte starts
-- at that byte, otherwise at the top 16 bits of its first primary (as ICU's
-- scriptStarts); the reserved ranges and the unassigned code points have no
-- name
local boundaries = {}
local version, unassigned_start, first_trail_byte
for line in io.lines("data/FractionalUCA.txt") do
  version = version or line:match("^%[UCA version = ([%d%.]+)%]")
  local trail = line:match("^%[fixed first trail byte (%x%x)%]")
  if trail then first_trail_byte = tonumber(trail, 16) end
  local mark, codepoint, primary = line:match("^(FDD[01]) (%x+);%s*%[([%x ]*),")
  if mark then
    codepoint = tonumber(codepoint, 16)
    local first = bytes_to_primary(primary)
    local start = first & 0xFFFF0000
    if line:match("starts new lead byte") then start = first & 0xFF000000 end
    -- scripts with the same first primary share the start
    for _, boundary in ipairs(boundaries) do
      if boundary.first == first then start = math.min(start, boundary.start); boundary.start = start end
    end
    if mark == "FDD1" and codepoint == 0xFDD0 then
      -- unassigned first primary: the end of the last group
      boundaries[#boundaries + 1] = {start = start, first = first}
      unassigned_start = start
    elseif mark == "FDD1" then
      local name = special_group(categories[codepoint]) or scripts[codepoint]
      if not name then error(string.format("no script for U+%04X", codepoint)) end
      boundaries[#boundaries + 1] = {start = start, first = first, name = name}
    elseif line:match("REORDER_RESERVED") then
      boundaries[#boundaries + 1] = {start = start, first = first}
    end
  end
end
table.sort(boundaries, function(a, b)
  if a.start ~= b.start then return a.start < b.start end
  return (a.name or "") < (b.name or "")
end)

-- the groups end before the next boundary with another start (the next
-- group, a reserved range or the unassigned code points); scripts with the
-- same start (Hiragana and Katakana, the two Meroitic scripts) are one
-- group, the other names are its aliases
local groups = {}
for i, boundary in ipairs(boundaries) do
  if boundary.name then
    local name, list = names_of(boundary.name)
    local last = groups[#groups]
    if last and last.min == boundary.start then
      io.stderr:write(string.format("merged groups: %s and %s\n", last.name, name))
      table.insert(last.aliases, name)
      for _, alias in ipairs(list) do table.insert(last.aliases, alias) end
    else
      local j = i + 1
      while boundaries[j] and boundaries[j].start == boundary.start do j = j + 1 end
      local nextboundary = assert(boundaries[j], "no boundary after " .. name)
      groups[#groups + 1] = {min = boundary.start, max = nextboundary.start - 1, name = name, aliases = list}
    end
  end
end

-- the unassigned code points: ICU's Zzzz range (FDD1 FDD0), up to the
-- trailing weights; moved with "others", it cannot be listed
groups[#groups + 1] = {min = unassigned_start, max = first_trail_byte * 0x1000000 - 1, name = "unassigned", aliases = {}}

-- the names of scripts without characters in the root collation (Zyyy,
-- Zinh, ...), ignored in a reordering as in ICU; other names are errors
local used = {}
for _, group in ipairs(groups) do
  used[group.name] = true
  for _, alias in ipairs(group.aliases) do used[alias] = true end
end
groups.unused = {}
for name, code in pairs(codes) do
  local long = name:lower():gsub("_", " ")
  if not used[long] and not used[code:lower()] then
    groups.unused[long] = true
    groups.unused[code:lower()] = true
  end
end

print("-- generated by tools/make_reordering_table.lua from FractionalUCA.txt (UCA " .. version .. ")")
print(serpent.dump(groups))
