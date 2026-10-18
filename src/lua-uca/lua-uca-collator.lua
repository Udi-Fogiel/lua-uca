-- object for Unicode string collation
local math = require "math"
local floor = math.floor
local tailoring_lib
local reordering_table
local implicit
local rules_lib
local builder
local root_info
local ccc
local digits
local uni_normalize
if kpse then
  tailoring_lib = require "lua-uca.lua-uca-tailoring"
  reordering_table = require "lua-uca.lua-uca-reordering-table"
  implicit = require "lua-uca.lua-uca-implicit"
  rules_lib = require "lua-uca.lua-uca-rules"
  builder = require "lua-uca.lua-uca-builder"
  root_info = require "lua-uca.lua-uca-root-info"
  ccc = require "lua-uca.lua-uca-ccc"
  digits = require "lua-uca.lua-uca-digits"
  -- in LuaTeX, load the lua-uni-normalize library (it needs Lua 5.3, it
  -- cannot be loaded in LuaJITTeX)
  local ok, library = pcall(require, "lua-uni-normalize")
  if ok then uni_normalize = library end
else
  tailoring_lib = require "lua-uca.tailoring"
  reordering_table = require "lua-uca.reordering-table"
  implicit = require "lua-uca.implicit"
  rules_lib = require "lua-uca.rules"
  builder = require "lua-uca.builder"
  root_info = require "lua-uca.root-info"
  ccc = require "lua-uca.ccc"
  digits = require "lua-uca.digits"
end

local utf8 = utf8
if jit then
  package.cpath = package.cpath .. ";?.dylib;?.so;?.dll"
  utf8 = require "lua-utf8" -- https://github.com/starwing/luautf8.git
end

local collator = {}

-- the options that apply when sort keys are made; they are kept in
-- collator_obj.settings, set by collator.new(codes, options), by
-- collator_obj:set(options), or by assigning them as fields of the collator
-- object; a change clears the cache of sort keys
local options = {
  -- "non-ignorable" (or nil), "shifted", "blanked"
  variable_weighting = {["non-ignorable"] = true, shifted = true, blanked = true},
  -- the variable characters: "space", "punct" (or nil, CLDR's default),
  -- "symbol", "currency", or "ducet" (those of the DUCET)
  max_variable = {space = true, punct = true, symbol = true, currency = true, ducet = true},
  accents_backward = "boolean",
  identical_level = "boolean",
  -- "upper", "lower", "off" (or nil)
  case_first = {upper = true, lower = true, off = true},
  case_level = "boolean",
  -- the levels compared: 1 (primary) to 4 (quaternary); nil: three levels,
  -- four with shifted variable weighting
  strength = {[1] = true, [2] = true, [3] = true, [4] = true},
  -- the order of Han characters: "implicit" (or nil, the order of the
  -- Unified_Ideograph ranges) or "radical-stroke"; only when the collator is
  -- created
  han_order = {implicit = true, ["radical-stroke"] = true},
  -- sequences of decimal digits sorted by their numeric value (UTS #35)
  numeric = "boolean",
}

local function set_option(self, name, value)
  local allowed = options[name]
  if not allowed then error("lua-uca: unknown option " .. tostring(name), 3) end
  if name == "han_order" and rawget(self, "created") then
    error("lua-uca: the option han_order can only be given to collator.new", 3)
  end
  if value ~= nil then
    if allowed == "boolean" then
      if type(value) ~= "boolean" then error("lua-uca: option " .. name .. " must be a boolean", 3) end
    elseif not allowed[value] then
      error("lua-uca: wrong value for option " .. name .. ": " .. tostring(value), 3)
    end
  end
  rawget(self, "settings")[name] = value
  rawset(self, "stringcache", {})
end

local instance = {
  __index = collator,
  __newindex = function(self, name, value)
    if options[name] then
      set_option(self, name, value)
    else
      rawset(self, name, value)
    end
  end,
}

-- Unicode normalization: the UCA requires NFD, used by default when
-- lua-uni-normalize is available
local normalize_method = uni_normalize and "NFD" or false

function collator.use_nfc()
  if uni_normalize then
    normalize_method = "NFC"
  else
    return nil, "lua-uni-normalize is not available"
  end
end

function collator.use_nfd()
  if uni_normalize then
    normalize_method = "NFD"
  else
    return nil, "lua-uni-normalize is not available"
  end
end


local function copy_table(tbl)
  local t = {}
  for  k, v in pairs(tbl) do
    if type(v) == "table" then
      t[k] = copy_table(v)
    else
      t[k] = v
    end
  end
  return t
end

collator.copy_table = copy_table

-- call fn for an entry of the table and every entry below it: its
-- contractions (children) and the entries of its prefix contexts
-- (prefixes: a tree of the preceding code points, in reverse, whose nodes
-- have an entry and the longer prefixes in more)
local function walk_entries(entry, fn)
  fn(entry)
  for _, child in pairs(entry.children or {}) do walk_entries(child, fn) end
  local function walk_prefixes(map)
    for _, node in pairs(map) do
      if node.entry then walk_entries(node.entry, fn) end
      if node.more then walk_prefixes(node.more) end
    end
  end
  if entry.prefixes then walk_prefixes(entry.prefixes) end
end
collator.walk_entries = walk_entries

function collator.new(codes, settings)
  local self = setmetatable({settings = {}}, instance)
  -- tree with mappings from codepoints to collation elements
  self.codes = copy_table(codes or {})
  -- the root collation, unchanged, for the case of tailored strings
  self.root_codes = codes or {}
  -- cached sort keys
  self.stringcache = {}
  self.tailoring_multiplier = {1, 1, 1, 1}
  for name, value in pairs(settings or {}) do set_option(self, name, value) end
  if self.settings.han_order == "radical-stroke" then
    self:use_radical_stroke()
  end
  rawset(self, "created", true)
  return self
end

-- change options
function collator:set(settings)
  for name, value in pairs(settings) do set_option(self, name, value) end
  return self
end

-- make tree that points weights back to codepoints
function collator:weight_to_codepoints(codes)
  local weights = {}
  local codes = codes or self.codes

  local function insert_weight(element, codepoints, weights)
    local values = element.value
    local weights = weights
    if values and not values.equal then
      values = values[1]
      local current = weights
      for i, weight in ipairs(values) do
        local new = current[weight] or {}
        -- multiple characters can have the same weight.
        if i == #values and not new.codepoints then
          new.codepoints = codepoints
        end
        current[weight] = new
        current = new
      end
    end
    local children = element.children or {}
    for codepoint, element in pairs(children) do
      -- make copy of the codes table, so the new codepoints are not added indefinitely
      local newcodes = {table.unpack(codepoints)}
      newcodes[#newcodes + 1] = codepoint
      insert_weight(element, newcodes, weights)
    end
  end
  for codepoint, element in pairs(codes) do
    insert_weight(element, {codepoint}, weights)
  end
  return weights
end

-- implicit weights (computed as in ICU), for the characters without mappings
-- in the root collation (lua-uca-root.lua, from CLDR's FractionalUCA.txt)
local han_ranges = implicit.han_ranges(root_info.han_ranges, root_info.unassigned_lead)

-- the radical-stroke order of Han (FractionalUCA.txt's [radical] lines),
-- loaded when it is used
local radical_ranges
local function get_radical_ranges()
  if not radical_ranges then
    local pairs_list
    if kpse then
      pairs_list = require "lua-uca.lua-uca-han-radical"
    else
      pairs_list = require "lua-uca.han-radical"
    end
    local ranges = {}
    for i = 1, #pairs_list, 2 do ranges[#ranges + 1] = {pairs_list[i], pairs_list[i + 1]} end
    radical_ranges = implicit.han_ranges(ranges, root_info.unassigned_lead)
  end
  return radical_ranges
end

-- Han characters in radical-stroke order: the implicit weights, and the
-- collation elements that refer to a Han character (the `han` field)
function collator:use_radical_stroke()
  local ranges = get_radical_ranges()
  rawset(self, "han_ranges", ranges)
  local function update(entry)
    for _, element in ipairs(entry.value or {}) do
      if element.han then element[1] = implicit.han_primary(element.han, ranges) end
    end
  end
  for _, entry in pairs(self.codes) do walk_entries(entry, update) end
end

function collator:get_implicit_weight(codepoints, pos)
  -- Han by the order of the Unified_Ideograph ranges (or radical-stroke),
  -- the others by their code point
  local codepoint = codepoints[pos]
  local primary = implicit.han_primary(codepoint, rawget(self, "han_ranges") or han_ranges)
    or implicit.unassigned_primary(codepoint, root_info.unassigned_lead)
  -- the implicit weights are moved with their script by reordering
  if self.reorder_moves then
    primary = tailoring_lib.move_primary(primary, self.reorder_moves)
  end
  return {{primary, root_info.common_secondary, root_info.common_tertiary}}, pos + 1
end

-- the weights of the longest match at pos, as ICU's CollationIterator: the
-- longest prefix context (the code points before pos), then its
-- contractions; when none of a context's contractions matches and it has no
-- mapping of its own, the next shorter context, and ultimately the mapping
-- without context (ICU's CONTRACT_SINGLE_CP_NO_MATCH)
function collator:read_weight(codepoints, pos)
  local codes = self.codes[codepoints[pos]]
  if not codes then return nil, pos + 1 end
  -- the entries of the matching contexts, from no context to the longest
  local chain
  local map = codes.prefixes
  if map then
    chain = {codes}
    local k = pos - 1
    while map and k >= 1 do
      local node = map[codepoints[k]]
      if not node then break end
      if node.entry then chain[#chain + 1] = node.entry end
      map = node.more
      k = k - 1
    end
  end
  -- the longest contraction from an entry
  local function read_children(parent, pos)
    local children = parent.children or {}
    local newpos = pos + 1
    local newcodepoint = codepoints[newpos]
    -- if we go out of the codepoint array
    if not newcodepoint then return nil end
    local child = children[newcodepoint]
    if child then
      local nextchild, nextpos, nextnode = read_children(child, newpos)
      if nextchild then return nextchild, nextpos, nextnode end
      if child.value then return child.value, newpos, child end
    end
    return nil
  end
  local weights, new_pos, node
  for j = chain and #chain or 1, 1, -1 do
    local entry = chain and chain[j] or codes
    weights, new_pos, node = read_children(entry, pos)
    if not weights and entry.value then
      weights, new_pos, node = entry.value, pos, entry
    end
    if weights then break end
  end
  if not weights then return nil, pos + 1 end
  -- discontiguous contractions (UTS #10, S2.1.1-S2.1.3): an unblocked
  -- non-starter after the match extends it when the longer string is in the
  -- database, and is removed from the codepoints
  local removed
  local i = new_pos + 1
  local blocking = 0 -- the highest combining class skipped
  while node.children do
    local codepoint = codepoints[i]
    local class = codepoint and ccc[codepoint]
    if not class then break end
    local child = node.children[codepoint]
    if child and child.value and blocking < class then
      weights, node = child.value, child
      removed = removed or {}
      removed[i] = true
    elseif class > blocking then
      blocking = class
    end
    i = i + 1
  end
  if removed then
    local remaining = {}
    for j = 1, #codepoints do
      if not removed[j] then remaining[#remaining + 1] = codepoints[j] end
    end
    return weights, new_pos + 1, remaining
  end
  return weights, new_pos + 1
end

-- the values of the decimal digits
local digit_values = {}
for _, zero in ipairs(digits) do
  for value = 0, 9 do digit_values[zero + value] = value end
end

-- the value of a digit for numeric collation: a decimal digit with a single
-- collation element, without contractions or contexts (ICU's DIGIT_TAG)
local function digit_value(self, codepoint)
  local value = digit_values[codepoint]
  if not value then return nil end
  local entry = self.codes[codepoint]
  if entry and (entry.children or entry.prefixes or not entry.value or #entry.value ~= 1) then
    return nil
  end
  return value
end

-- the collation elements of a number, as ICU's appendNumericSegmentCEs: the
-- numeric lead byte, then the value in the second byte and the next ones
-- (small numbers), or the number of digit pairs and the pairs; length is at
-- most 254 digits
local function numeric_segment(list, digits, first, length)
  local numeric_primary = root_info.numeric_primary
  local function add(primary)
    list[#list + 1] = {primary, root_info.common_secondary, root_info.common_tertiary}
  end
  if length <= 7 then
    local value = 0
    for i = first, first + length - 1 do value = value * 10 + digits[i] end
    -- 74 second bytes (2..75) for 0..73 in two bytes
    if value < 74 then
      return add(numeric_primary + (2 + value) * 0x10000)
    end
    -- 40 second bytes (76..115) for 74..10233 in three bytes
    value = value - 74
    if value < 40 * 254 then
      return add(numeric_primary + (76 + floor(value / 254)) * 0x10000 + (2 + value % 254) * 0x100)
    end
    -- 16 second bytes (116..131) for 10234..1042489 in four bytes
    value = value - 40 * 254
    if value < 16 * 254 * 254 then
      local primary = numeric_primary + 2 + value % 254
      value = floor(value / 254)
      primary = primary + (2 + value % 254) * 0x100
      value = floor(value / 254)
      return add(primary + (116 + value % 254) * 0x10000)
    end
  end
  -- the second bytes 132..255: the number of digit pairs (4..127), then
  -- the pairs (11 + 2 * pair) without the trailing 00 pairs, the last one
  -- less one
  local pairs_count = floor((length + 1) / 2)
  local primary = numeric_primary + (132 - 4 + pairs_count) * 0x10000
  local last = first + length - 1
  while digits[last] == 0 and digits[last - 1] == 0 do last = last - 2 end
  local pair, pos
  if (last - first + 1) % 2 == 1 then
    pair, pos = digits[first], first + 1
  else
    pair, pos = digits[first] * 10 + digits[first + 1], first + 2
  end
  pair = 11 + 2 * pair
  local shift = 0x100
  while pos <= last do
    if shift == 1 then
      -- every three pairs a new collation element, with the numeric lead byte
      add(primary + pair)
      primary = numeric_primary
      shift = 0x10000
    else
      primary = primary + pair * shift
      shift = floor(shift / 0x100)
    end
    pair = 11 + 2 * (digits[pos] * 10 + digits[pos + 1])
    pos = pos + 2
  end
  add(primary + (pair - 1) * shift)
end

-- the collation elements of the digits from pos, as ICU's appendNumericCEs:
-- without the leading zeros, in segments of at most 254 digits
local function numeric_weights(self, codepoints, pos)
  local values = {}
  local next_pos = pos
  while true do
    local value = codepoints[next_pos] and digit_value(self, codepoints[next_pos])
    if not value then break end
    values[#values + 1] = value
    next_pos = next_pos + 1
  end
  local list = {}
  local start = 1
  repeat
    while start < #values and values[start] == 0 do start = start + 1 end
    local length = math.min(#values - start + 1, 254)
    numeric_segment(list, values, start, length)
    start = start + length
  until start > #values
  -- the numeric weights are moved with the digits by reordering
  if self.reorder_moves then
    for _, element in ipairs(list) do
      element[1] = tailoring_lib.move_primary(element[1], self.reorder_moves)
    end
  end
  return list, next_pos
end

-- get weights for the next characters
-- when a discontiguous contraction was matched, the codepoints without the
-- removed characters are returned as the third value
function collator:get_weights(codepoints, pos)
  if rawget(self, "pending_rules") then self:apply_rules() end
  if self.settings.numeric and digit_value(self, codepoints[pos]) then
    local weights, next_pos = numeric_weights(self, codepoints, pos)
    if next_pos > #codepoints then next_pos = nil end
    return weights, next_pos
  end
  local weights, next_pos, remaining = self:read_weight(codepoints, pos)
  -- return implicit weights for codepoints that are not in the database
  if not weights then
    weights, next_pos = self:get_implicit_weight(codepoints, pos)
  end
  -- don't step next_pos if it is larger than size of the codepoints array
  if next_pos > #(remaining or codepoints) then next_pos = nil end
  return weights, next_pos, remaining
end

-- get characters with lowest weight at the given point of the codepoint array
-- useful for index header strings
function collator:get_lowest_char(codepoints, pos)
  if rawget(self, "pending_rules") then self:apply_rules() end
  -- find the lowest key in the table
  local min = math.min
  local max = math.max
  local pos = pos or 1
  local minimal = 0xffffffffff
  local maximal = -0xfffffffff
  local function get_lowest_key(tbl)
    local minimal, maximal = minimal, maximal
    if tbl.minimal then return tbl.minimal, tbl.maximal end
    for k,v in pairs(tbl) do
      minimal,maximal = min(k, minimal), max(k, maximal)
    end
    tbl.minimal, tbl.maximal = minimal, maximal
    return minimal, maximal
  end

  -- traverse tree, select lowest keys and find the codepoints
  local function find_codepoints(tbl, level)
    local level = level or 1
    local tbl = tbl or {}
    if tbl.codepoints then return tbl.codepoints end
    local newmin, newmax = get_lowest_key(tbl)
    -- this shouldn't happen
    if newmin == minimal then return nil end
    return find_codepoints(tbl[newmin], level + 1)
  end


  local weights, next_pos = self:read_weight(codepoints, pos)
  local x
  if weights then
    local weight_to_char = self.weight_to_char or self:weight_to_codepoints()
    self.weight_to_char = weight_to_char
    -- find the primary weight of the matched character
    local first = weights[1][1]
    local current = weight_to_char[first]
    -- traverse the tree to find the codepoint with the lowest weight
    x = find_codepoints(current)
  end
  -- the result is meant for display, return it in NFC
  if x and uni_normalize then
    local composed = {}
    for _, code in utf8.codes(uni_normalize.NFC(utf8.char(table.unpack(x)))) do
      composed[#composed + 1] = code
    end
    x = composed
  end
  return x, next_pos
end

function collator:update_levels(levels, weights)
  -- process weight weights
  for _, w in ipairs(weights) do
    for i, x in ipairs(w) do
      --  process collation elements
      if x ~= 0 then -- ignore zero elements
        -- insert element at the current collation level
        local current_level = levels[i] or {}
        table.insert(current_level, x)
        levels[i] = current_level
      end
    end
  end
  return levels
end



-- the primary weight of U+FFFE, which separates the segments for backward
-- levels (UTS #10, 10.1.5)
local segment_separator = root_info.merge_separator
-- the primary weights of the variable collation elements are above U+FFFE's
-- and at most the variable top of max_variable
local variable_tops = root_info.variable_tops
-- the quaternary weight of the non-ignorable collation elements, above every
-- primary weight; with the quaternary differences of tailorings (the
-- quaternary field, 0 to 3) added
local common_quaternary = 0xFFFFFFFC

-- case parameters (UTS #35, Case Parameters): the case value of a collation
-- element (its case field: 0 uncased or lowercase, 1 mixed, 2 uppercase)
-- gives a weight c, from uppercase first (case_first = "upper") or lowercase
-- first; with case_level, c is a level before the tertiary one, without it
-- c is combined with the tertiary weight, above it
local case_weight = {
  upper = {[0] = 3, [1] = 2, [2] = 1},
  lower = {[0] = 1, [1] = 2, [2] = 3},
}
local tertiary_range = 0x10000

local function case_weights(weights, case_first, case_level, strength)
  local c_of = case_weight[case_first == "upper" and "upper" or "lower"]
  local new = {}
  for i, element in ipairs(weights) do
    local p, s, t = element[1], element[2], element[3]
    local c = c_of[element.case or 0]
    local changed
    if case_level then
      if p == 0 and (s == 0 or strength == 1) then
        -- tertiary and tertiary-ignorable collation elements have no case,
        -- at strength 1 neither have the primary ignorable ones
        changed = {0, s, 0, t}
      else
        changed = {p, s, c, t}
      end
    else
      if p == 0 and s == 0 and t == 0 then
        changed = {0, 0, 0}
      elseif p == 0 and s == 0 then
        -- tertiary collation elements: 3, so that they stay above the
        -- others (UCA's WF2)
        changed = {0, 0, 3 * tertiary_range + t}
      else
        changed = {p, s, c * tertiary_range + t}
      end
    end
    changed.quaternary = element.quaternary
    new[i] = changed
  end
  return new
end

-- variable weighting (UTS #10, section 4): the option variable_weighting is
-- "non-ignorable" (the default), "shifted" or "blanked"
-- the weights of the variable collation elements and of the ignorable ones
-- after them are reset to zero; shifted adds a quaternary level, with the
-- old primary weight of the variable collation elements, FFFFFFFC (plus a
-- tailored quaternary difference) for the other non-ignorable ones
local function variable_weights(weights, levels, shifted, after_variable, variable_top, inverse)
  local new = {}
  for i, element in ipairs(weights) do
    local reset, quaternary
    -- variable or not by the weight before script reordering (UTS #35)
    local primary = element[1]
    if inverse and primary ~= 0 then primary = tailoring_lib.move_primary(primary, inverse) end
    if primary > segment_separator and primary <= variable_top then
      -- variable collation element
      reset, quaternary, after_variable = true, element[1], true
    elseif element[1] == 0 then
      -- ignorable collation element
      if after_variable then
        reset, quaternary = true, 0
      else
        local completely_ignorable = true
        for level = 2, levels do
          if element[level] ~= 0 then completely_ignorable = false end
        end
        reset, quaternary = false, completely_ignorable and 0 or common_quaternary + (element.quaternary or 0)
      end
    else
      reset, quaternary, after_variable = false, common_quaternary + (element.quaternary or 0), false
    end
    local changed = {}
    for level = 1, levels do
      changed[level] = reset and 0 or element[level]
    end
    if shifted then changed[levels + 1] = quaternary end
    new[i] = changed
  end
  return new, after_variable
end

-- make sort key from codepoints array (it can be created using the utf8.codes() function
function collator:make_sort_key(codepoints)
  local levels = {}
  local pos = 1
  local weights, remaining
  local sort_key = {}
  local original = codepoints
  -- positions of the U+FFFE weights in the secondary level
  local separators = {}
  local settings = self.settings
  local case_first = settings.case_first
  if case_first == "off" then case_first = nil end
  local case_level = settings.case_level
  local strength = settings.strength
  -- the number of levels in the collation elements
  local element_levels = case_level and 4 or 3
  local variable = settings.variable_weighting
  if variable == "non-ignorable" then variable = nil end
  -- the quaternary level: at strength 4, by default with shifted
  local quaternary = strength == 4 or (strength == nil and variable == "shifted")
  local variable_top = variable_tops[settings.max_variable or "punct"]
  local after_variable = false
  while true do
    --
    weights, pos, remaining = self:get_weights(codepoints, pos)
    codepoints = remaining or codepoints
    if case_first or case_level then
      weights = case_weights(weights, case_first, case_level, strength)
    end
    if variable then
      weights, after_variable = variable_weights(weights, element_levels, variable == "shifted", after_variable, variable_top, rawget(self, "reorder_inverse"))
    end
    if quaternary and variable ~= "shifted" then
      -- the quaternary weights of the tailorings
      local new = {}
      for i, element in ipairs(weights) do
        local changed = {}
        local ignorable = true
        for level = 1, element_levels do
          changed[level] = element[level]
          if element[level] ~= 0 then ignorable = false end
        end
        changed[element_levels + 1] = ignorable and 0 or common_quaternary + (element.quaternary or 0)
        new[i] = changed
      end
      weights = new
    end
    if settings.accents_backward then
      for _, element in ipairs(weights) do
        if element[1] == segment_separator then
          separators[#separators + 1] = #(levels[2] or {}) + 1
        end
        levels = self:update_levels(levels, {element})
      end
    else
      levels = self:update_levels(levels, weights)
    end
    -- break when we reach end of the codepoints array
    if not pos then break end
  end
  -- (df) Reverse sort for accents?
  -- the secondary weights are reversed in each segment between the U+FFFE
  -- weights (UTS #10, S3.6), the U+FFFE weights stay in place
  if settings.accents_backward and levels[2] and strength ~= 1 then
    local secondary = levels[2]
    separators[#separators + 1] = #secondary + 1
    local start = 1
    for _, separator in ipairs(separators) do
      local stop = separator - 1
      while stop > start do
        secondary[start], secondary[stop] = secondary[stop], secondary[start]
        start = start + 1
        stop = stop - 1
      end
      start = separator + 1
    end
  end
  -- every level up to the strength is in the sort key, also when it has no
  -- weights: primary, secondary, the case level, tertiary, quaternary
  local included = {1}
  if strength ~= 1 then included[#included + 1] = 2 end
  if case_level then included[#included + 1] = 3 end
  if strength == nil or strength >= 3 then included[#included + 1] = element_levels end
  if quaternary then included[#included + 1] = element_levels + 1 end
  for _, i in ipairs(included) do
    for _, element in ipairs(levels[i] or {}) do
      table.insert(sort_key, element)
    end
    -- zero separates levels in the sort key
    table.insert(sort_key, 0)
  end
  -- the identical level (UTS #10, S3.10): the NFD code points, shifted by 2
  -- so that they are above the level separator, U+FFFE with the minimal
  -- weight 1
  if settings.identical_level then
    local nfd = original
    if normalize_method ~= "NFD" and uni_normalize then
      nfd = {}
      for _, code in utf8.codes(uni_normalize.NFD(utf8.char(table.unpack(original)))) do
        nfd[#nfd + 1] = code
      end
    end
    for _, code in ipairs(nfd) do
      table.insert(sort_key, code == 0xFFFE and 1 or code + 2)
    end
  end
  return sort_key
end

function collator:compare(a, b)
  -- sort using sort keys
  local min = math.min(#a, #b)
  for i = 1, min do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  -- this should happen only when the strings are equal
  -- it needs to return false, otherwise the table.sort function reports
  -- "invalid order function for sorting" error
  return #a < #b
end

local codepoints_cache = {}

function collator:string_to_codepoints(a)
  if codepoints_cache[a] then return codepoints_cache[a] end
  -- try unicode normalization, if it is available
  -- it uses libraries available in LuaTeX, so it doesn't work with
  -- stock Lua
  local normalized = a
  if normalize_method then
    normalized = uni_normalize[normalize_method](a)
  end
  local codepoints = {}
  for _, code in utf8.codes(normalized) do codepoints[#codepoints+1] = code end
  codepoints_cache[a] = codepoints
  return codepoints
end

function collator:compare_strings(a,b)
  -- sort using strings
  local cache = self.stringcache
  local get_sortkey = function(x) return self:make_sort_key(self:string_to_codepoints(x)) end
  local asortkey = cache[a] or get_sortkey(a)
  local bsortkey = cache[b] or get_sortkey(b)
  cache[a], cache[b] = asortkey, bsortkey
  return self:compare(asortkey, bsortkey)
end

-- a mapping with a prefix context: key after prefix
function collator:update_prefix(prefix, key, elements)
  local first = key[1]
  local entry = self.codes[first]
  if not entry then
    entry = {}
    self.codes[first] = entry
  end
  entry.prefixes = entry.prefixes or {}
  local map, node = entry.prefixes
  for i = #prefix, 1, -1 do
    node = map[prefix[i]]
    if not node then
      node = {}
      map[prefix[i]] = node
    end
    if i > 1 then
      node.more = node.more or {}
      map = node.more
    end
  end
  node.entry = node.entry or {}
  local target = node.entry
  for i = 2, #key do
    target.children = target.children or {}
    local child = target.children[key[i]] or {}
    target.children[key[i]] = child
    target = child
  end
  target.value = elements
end

-- update collation codes
function collator:update_codes(key, elements)
  local keys = self.codes
  local function add_to_tree(tbl, current_pos)
    local tbl = tbl or {}
    local current_key = key[current_pos]
    local el =  tbl[current_key] or {}
    if current_pos < #key then
      el.children = add_to_tree(el.children, current_pos + 1)
    elseif current_pos == #key then
      el.value = elements
    end
    tbl[current_key] = el
    return tbl
  end
  keys = add_to_tree(keys, 1)
end


--- change sorting ordering
--
-- the collation elements of codepoints in the root collation
function collator:root_weights(codepoints)
  local codes = self.codes
  self.codes = self.root_codes
  local weights, pos = {}, 1
  while pos do
    local value
    value, pos = self:get_weights(codepoints, pos)
    for _, element in ipairs(value) do weights[#weights + 1] = element end
  end
  self.codes = codes
  return weights
end

-- set the case of the collation elements of a tailored string from its root
-- collation elements (UTS #35, Case Parameters, Tailored Strings)
function collator:set_tailored_case(target, value)
  local root_primaries = {}
  for _, element in ipairs(self:root_weights(target)) do
    if element[1] ~= 0 then root_primaries[#root_primaries + 1] = element.case or 0 end
  end
  local n = #root_primaries
  local m = 0
  for _, element in ipairs(value) do if element[1] ~= 0 then m = m + 1 end end
  local i = 0
  for _, element in ipairs(value) do
    local case = 0
    if element[1] ~= 0 then
      i = i + 1
      if n <= m or i < m then
        case = root_primaries[i] or 0
      else
        -- the last tailored primary gets the case of the remaining root
        -- primaries: lowercase, uppercase, or mixed
        local lower, upper = true, true
        for j = m, n do
          if root_primaries[j] ~= 0 then lower = false end
          if root_primaries[j] ~= 2 then upper = false end
        end
        case = lower and 0 or upper and 2 or 1
      end
    elseif element[2] == 0 and element[3] ~= 0 then
      -- tertiary collation elements are uppercase
      case = 2
    end
    element.case = case ~= 0 and case or nil
  end
  return value
end

function collator:tailor(base, target, tailoring_table)
  if rawget(self, "pending_rules") then self:apply_rules() end
  -- get the value of the base character
  local value = self:get_weights(base, 1)
  local new_value = {}
  --  create a new collation element
  for k, v in ipairs(value) do
    local subtable = {}
    for x, y in ipairs(v) do
      subtable[x] = y + ((tailoring_table[x] or 0) * self.tailoring_multiplier[x] or 1)
    end
    new_value[k] = subtable
  end
  -- when tailoring sets an equivialent character, it needs to be ignored in collator:weight_to_codepoints
  local is_equivalent = 0
  for _, x in ipairs(tailoring_table) do is_equivalent = is_equivalent + x end
  if is_equivalent == 0 then new_value.equal = true end
  self:update_codes(target, self:set_tailored_case(target, new_value))
end

-- support for CLDR style strings
-- the settings of the rule syntax (checked by the parser), as options
local rule_settings = {
  strength = function(self, value)
    if value == "I" then
      self:set {strength = 4, identical_level = true}
    else
      self:set {strength = value}
    end
  end,
  alternate = function(self, value) self:set {variable_weighting = value} end,
  backwards = function(self) self:set {accents_backward = true} end,
  caseLevel = function(self, value) self:set {case_level = value} end,
  caseFirst = function(self, value) self:set {case_first = value} end,
  maxVariable = function(self, value) self:set {max_variable = value} end,
  -- the input is always normalized when it can be
  normalization = function() end,
  numericOrdering = function(self, value) self:set {numeric = value} end,
  hiraganaQ = function() end,
  import = function(self, value) error("lua-uca: [import " .. value .. "] is not supported", 0) end,
  -- only makes the tables smaller in ICU
  optimize = function() end,
  -- applied by the builder, where it occurs in the rules
  suppressContractions = function() end,
}

-- TODO: exact checks with lua-normalization once it is released: an NFC
-- boundary before c when the first character of its canonical decomposition
-- has combining class 0 and NFC_QC is not Maybe (ICU's hasBoundaryBefore);
-- NFD-inert from its decompositions, also without lua-uni-normalize
-- the checks of the parser: a character starts an NFC boundary (approximated:
-- combining class 0, not a Hangul vowel or trailing consonant, and its NFD
-- starting with combining class 0), a character is NFD-inert (combining
-- class 0 and no canonical decomposition); without lua-uni-normalize, only
-- the combining classes are checked
local function nfd_of(c)
  if not uni_normalize then return {c} end
  local list = {}
  for _, code in utf8.codes(uni_normalize.NFD(utf8.char(c))) do list[#list + 1] = code end
  return list
end
local rule_checks = {
  boundary = function(c)
    if ccc[c] or (c >= 0x1161 and c <= 0x1175) or (c >= 0x11A8 and c <= 0x11C2) then return false end
    return not ccc[nfd_of(c)[1]]
  end,
  inert = function(c)
    if ccc[c] then return false end
    local nfd = nfd_of(c)
    return #nfd == 1 and nfd[1] == c
  end,
}

-- support for CLDR style rules (UTS #35, Collation Tailorings); the rules of
-- several calls are collected and built together when the collator is used,
-- as one rule text, so that the new weights of all of them are spaced in
-- their gaps at once
function collator:tailor_string(s)
  -- the escapes are those of the rules in data (ICU's u_unescape)
  local items = rules_lib.parse(rules_lib.unescape(s), rule_checks)
  local pending = rawget(self, "pending_rules")
  if not pending then
    pending = {}
    rawset(self, "pending_rules", pending)
  end
  for _, item in ipairs(items) do pending[#pending + 1] = item end
end

-- build the collected rules
-- the start of the Han group, for [last regular]
local han_group_start
for _, group in ipairs(reordering_table) do
  if group.name == "han" then han_group_start = group.min end
end

-- as ICU, a tailoring is built from the root with all of its rules: the
-- rules of a new call are added to the earlier ones, and the table is built
-- again (changes made with the tailor and equal methods are lost); the
-- reordering and the Han order are applied again
function collator:apply_rules()
  local pending = rawget(self, "pending_rules")
  if not pending then return end
  rawset(self, "pending_rules", nil)
  local items = rawget(self, "rule_items") or {}
  for _, item in ipairs(pending) do items[#items + 1] = item end
  rawset(self, "rule_items", items)
  self.codes = copy_table(self.root_codes)
  rawset(self, "reorder_moves", nil)
  rawset(self, "reorder_inverse", nil)
  if rawget(self, "han_ranges") then self:use_radical_stroke() end
  builder.build(self, items, {
    implicit = implicit,
    root_info = root_info,
    han_ranges = rawget(self, "han_ranges") or han_ranges,
    han_group_start = han_group_start,
  })
  local reorder
  for _, item in ipairs(items) do
    if item.kind == "setting" then
      if item.name == "reorder" then
        reorder = #item.value > 0 and item.value or {"others"}
      elseif rule_settings[item.name] then
        rule_settings[item.name](self, item.value)
      else
        error("lua-uca: the setting [" .. item.name .. "] is not supported", 0)
      end
    end
  end
  reorder = reorder or rawget(self, "reorder_codes")
  if reorder then self:reorder(reorder) end
end

-- reorder scripts
-- pass table with script names to reorder
function collator:reorder(tbl)
  if rawget(self, "pending_rules") then self:apply_rules() end
  -- make table of the reordering table (an error in the codes leaves the
  -- collator unchanged)
  local t = copy_table(reordering_table)
  for _, script in ipairs(tbl) do
    -- reorder scripts
    tailoring_lib.reorder(script, t)
  end
  -- kept, to be applied again when new rules are built
  rawset(self, "reorder_codes", tbl)
  -- apply reordering to the collator object
  tailoring_lib.reorder_collator(self, t)
end

-- expand characters to another characters
function collator:equal(base, target)
  if rawget(self, "pending_rules") then self:apply_rules() end
  local new_weight = {}
  local value, pos
  pos = 1
  while true do
    value, pos = self:get_weights(target, pos)
    for _, v in ipairs(value) do
      new_weight[#new_weight + 1] = {v[1], v[2], v[3], case = v.case}
    end
    if not pos then break end
  end
  self:update_codes(base, self:set_tailored_case(base, new_weight))
end

-- sort uppercase first: the same as the option case_first = "upper"
function collator:uppercase_first()
  self:set {case_first = "upper"}
end

return collator
