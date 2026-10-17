-- the tailoring builder, a port of ICU's CollationBuilder
-- (collationbuilder.cpp), with CollationRootElements
-- (collationrootelements.cpp) and CollationWeights (collationweights.cpp);
-- builder.build(collator, items, deps) applies the items of rules.parse to
-- the collator, whose table starts as a copy of the root collation
-- weights: primaries 32 bits, secondaries and tertiaries 16 bits, case in the
-- case field, quaternary (0-3) in the quaternary field
-- TODO: ICU's canonical closure (addWithClosure, addTailComposites,
-- closeOverComposites) and the mappings of the strings as written
-- (addIfDifferent): needed only for input that is not normalized to NFD
-- (without lua-uni-normalize, or with use_nfc)
local floor = math.floor
local unpack = table.unpack or unpack
local utf8 = utf8 or require "lua-utf8"

local M = {}

local PRIMARY, SECONDARY, TERTIARY, QUATERNARY, IDENTICAL = 1, 2, 3, 4, 5
local COMMON_WEIGHT16 = 0x0500
local BEFORE_WEIGHT16 = 0x0100
local COMMON_SEC_AND_TER = COMMON_WEIGHT16 * 0x10000 + COMMON_WEIGHT16

local function fail(message)
  error("lua-uca: tailoring: " .. message, 0)
end

-- bytes of 32-bit weights, without the integer operators of Lua 5.3
local function pow256(n) return 256 ^ n end
local function byte_of(w, index) return floor(w / pow256(4 - index)) % 256 end
local function set_byte(w, index, byte)
  return w + (byte - byte_of(w, index)) * pow256(4 - index)
end
local function truncate(w, length)
  local unit = pow256(4 - length)
  return floor(w / unit) * unit
end
local function set_trail(w, length, trail)
  return truncate(w, length - 1) + trail * pow256(4 - length)
end
local function length_of(w)
  if w % 0x1000000 == 0 then return 1 end
  if w % 0x10000 == 0 then return 2 end
  if w % 0x100 == 0 then return 3 end
  return 4
end

---------------------------------------------------------------------------
-- CollationWeights: weights between two limits, shortest first
---------------------------------------------------------------------------

local function new_weights(min_bytes, max_bytes, middle_length)
  local self = {}

  local function count_bytes(length) return max_bytes[length] - min_bytes[length] + 1 end

  local function inc_weight(w, length)
    while true do
      local b = byte_of(w, length)
      if b < max_bytes[length] then return set_byte(w, length, b + 1) end
      w = set_byte(w, length, min_bytes[length])
      length = length - 1
    end
  end
  local function inc_weight_by_offset(w, length, offset)
    while true do
      offset = offset + byte_of(w, length)
      if offset <= max_bytes[length] then return set_byte(w, length, offset) end
      offset = offset - min_bytes[length]
      w = set_byte(w, length, min_bytes[length] + offset % count_bytes(length))
      offset = floor(offset / count_bytes(length))
      length = length - 1
    end
  end
  local function lengthen_range(range)
    local length = range.length + 1
    range.start = set_trail(range.start, length, min_bytes[length])
    range.last = set_trail(range.last, length, max_bytes[length])
    range.count = range.count * count_bytes(length)
    range.length = length
  end

  local function get_weight_ranges(lower_limit, upper_limit)
    local lower_length, upper_length = length_of(lower_limit), length_of(upper_limit)
    if lower_limit >= upper_limit then return false end
    if lower_length < upper_length and lower_limit == truncate(upper_limit, lower_length) then
      return false
    end
    local lower, upper = {}, {}
    for l = 1, 4 do lower[l] = {count = 0}; upper[l] = {count = 0} end
    local middle = {count = 0}
    local w = lower_limit
    for length = lower_length, middle_length + 1, -1 do
      local trail = byte_of(w, length)
      if trail < max_bytes[length] then
        lower[length] = {start = w + pow256(4 - length), last = set_trail(w, length, max_bytes[length]),
          length = length, count = max_bytes[length] - trail}
      end
      w = truncate(w, length - 1)
    end
    if w < 0xFF000000 then
      middle.start = w + pow256(4 - middle_length)
    else
      middle.start = 0xFFFFFFFF
    end
    w = upper_limit
    for length = upper_length, middle_length + 1, -1 do
      local trail = byte_of(w, length)
      if trail > min_bytes[length] then
        upper[length] = {start = set_trail(w, length, min_bytes[length]), last = w - pow256(4 - length),
          length = length, count = trail - min_bytes[length]}
      end
      w = truncate(w, length - 1)
    end
    middle.last = w - pow256(4 - middle_length)
    middle.length = middle_length
    if middle.last >= middle.start then
      middle.count = floor((middle.last - middle.start) / pow256(4 - middle_length)) + 1
    else
      -- no middle range, eliminate overlaps
      for length = 4, middle_length + 1, -1 do
        if lower[length].count > 0 and upper[length].count > 0 then
          local lower_end, upper_start = lower[length].last, upper[length].start
          local merged = false
          if lower_end > upper_start then
            lower[length].last = upper[length].last
            lower[length].count = byte_of(lower[length].last, length) - byte_of(lower[length].start, length) + 1
            merged = true
          elseif lower_end ~= upper_start and inc_weight(lower_end, length) == upper_start then
            lower[length].last = upper[length].last
            lower[length].count = lower[length].count + upper[length].count
            merged = true
          end
          if merged then
            upper[length].count = 0
            for l = length - 1, middle_length + 1, -1 do
              lower[l].count = 0
              upper[l].count = 0
            end
            break
          end
        end
      end
    end
    local ranges = {}
    if middle.count > 0 then ranges[#ranges + 1] = middle end
    for length = middle_length + 1, 4 do
      if upper[length].count > 0 then ranges[#ranges + 1] = upper[length] end
      if lower[length].count > 0 then ranges[#ranges + 1] = lower[length] end
    end
    self.ranges = ranges
    return #ranges > 0
  end

  local function alloc_in_short_ranges(n, min_length)
    local ranges = self.ranges
    for i = 1, #ranges do
      if ranges[i].length > min_length + 1 then break end
      if n <= ranges[i].count then
        if ranges[i].length > min_length then ranges[i].count = n end
        for j = #ranges, i + 1, -1 do ranges[j] = nil end
        table.sort(ranges, function(a, b) return a.start < b.start end)
        return true
      end
      n = n - ranges[i].count
    end
    return false
  end
  local function alloc_in_min_length_ranges(n, min_length)
    local ranges = self.ranges
    local count, k = 0, 0
    while k < #ranges and ranges[k + 1].length == min_length do
      k = k + 1
      count = count + ranges[k].count
    end
    local next_count_bytes = count_bytes(min_length + 1)
    if n > count * next_count_bytes then return false end
    local start, finish = ranges[1].start, ranges[1].last
    for i = 2, k do
      if ranges[i].start < start then start = ranges[i].start end
      if ranges[i].last > finish then finish = ranges[i].last end
    end
    local count2 = floor((n - count) / (next_count_bytes - 1))
    local count1 = count - count2
    if count2 == 0 or (count1 + count2 * next_count_bytes) < n then
      count2 = count2 + 1
      count1 = count1 - 1
    end
    local first = {start = start, length = min_length}
    if count1 == 0 then
      first.last = finish
      first.count = count
      lengthen_range(first)
      self.ranges = {first}
    else
      first.last = inc_weight_by_offset(start, min_length, count1 - 1)
      first.count = count1
      local second = {start = inc_weight(first.last, min_length), last = finish, length = min_length, count = count2}
      lengthen_range(second)
      self.ranges = {first, second}
    end
    return true
  end

  function self.alloc(lower_limit, upper_limit, n)
    if not get_weight_ranges(lower_limit, upper_limit) then return false end
    while true do
      local min_length = self.ranges[1].length
      if alloc_in_short_ranges(n, min_length) then break end
      if min_length == 4 then return false end
      if alloc_in_min_length_ranges(n, min_length) then break end
      for i = 1, #self.ranges do
        if self.ranges[i].length ~= min_length then break end
        lengthen_range(self.ranges[i])
      end
    end
    self.index = 1
    return true
  end
  function self.next_weight()
    local range = self.ranges[self.index]
    if not range then return 0xFFFFFFFF end
    local w = range.start
    range.count = range.count - 1
    if range.count == 0 then
      self.index = self.index + 1
    else
      range.start = inc_weight(w, range.length)
    end
    return w
  end
  return self
end

-- CollationWeights::initForPrimary (lead bytes from 03, after the merge
-- separator 02), initForSecondary, initForTertiary (16 bits, the tertiary
-- bytes up to 3F)
-- in compressible lead bytes, the second byte is 04..FE
-- (the byte ranges by length 1 to 4)
local function primary_weights(compressible)
  if compressible then
    return new_weights({3, 4, 2, 2}, {0xFF, 0xFE, 0xFF, 0xFF}, 1)
  end
  return new_weights({3, 2, 2, 2}, {0xFF, 0xFF, 0xFF, 0xFF}, 1)
end
local function secondary_weights()
  return new_weights({0, 0, 2, 2}, {0, 0, 0xFF, 0xFF}, 3)
end
local function tertiary_weights()
  return new_weights({0, 0, 2, 2}, {0, 0, 0x3F, 0x3F}, 3)
end

---------------------------------------------------------------------------
-- CollationRootElements: the weights of the root collation
---------------------------------------------------------------------------

local function sorted_unique(list)
  table.sort(list)
  local unique = {}
  for _, v in ipairs(list) do if v ~= unique[#unique] then unique[#unique + 1] = v end end
  return unique
end
-- the first index with list[i] > w
local function upper_bound(list, w)
  local low, high = 1, #list
  while low <= high do
    local mid = floor((low + high) / 2)
    if list[mid] <= w then low = mid + 1 else high = mid - 1 end
  end
  return low
end

local function new_root_elements(root_codes, root_info, implicit, han_ranges)
  local primaries, sec_ter, secondary_ces, tertiary_ces = {}, {}, {}, {}
  local function add(element)
    local p, s, t = element[1], element[2], element[3]
    if p ~= 0 then
      primaries[#primaries + 1] = p
      local list = sec_ter[p]
      if not list then list = {COMMON_SEC_AND_TER}; sec_ter[p] = list end
      list[#list + 1] = s * 0x10000 + t
    elseif s ~= 0 then
      secondary_ces[#secondary_ces + 1] = s * 0x10000 + t
    elseif t ~= 0 then
      tertiary_ces[#tertiary_ces + 1] = t
    end
  end
  local function walk(entry)
    for _, element in ipairs(entry.value or {}) do add(element) end
    for _, child in pairs(entry.children or {}) do walk(child) end
  end
  -- not U+FFFE, the merge separator (collationbasedatabuilder.cpp)
  for code, entry in pairs(root_codes) do
    if code ~= 0xFFFE then walk(entry) end
  end
  -- a tailoring boundary, but not a mapping, for [first trailing]
  add({root_info.first_trail_byte * 0x1000000 + 0x020200, COMMON_WEIGHT16, COMMON_WEIGHT16})
  -- the collation elements of the FDD0 contractions, not mappings
  for _, element in ipairs(root_info.root_elements or {}) do add(element) end
  primaries = sorted_unique(primaries)
  for p, list in pairs(sec_ter) do sec_ter[p] = sorted_unique(list) end
  secondary_ces = sorted_unique(secondary_ces)
  tertiary_ces = sorted_unique(tertiary_ces)

  local R = {}
  -- FractionalUCA.txt's fixed bytes: first ignorable secondary 80, first
  -- ignorable tertiary 3C, last secondary common 45
  R.secondary_boundary = 0x8000
  R.tertiary_boundary = 0x3C00
  R.last_common_secondary = 0x4500
  R.variable_top = root_info.variable_top
  R.first_trailing_primary = root_info.first_trail_byte * 0x1000000 + 0x020200
  R.unassigned_lead = root_info.unassigned_lead
  local compressible = {}
  for _, lead in ipairs(root_info.compressible or {}) do compressible[lead] = true end
  function R.is_compressible(p) return compressible[floor(p / 0x1000000)] == true end

  local function is_han(p)
    local _, nextone = implicit.han_neighbors(p - 1, han_ranges)
    return nextone == p
  end
  -- the sec/ter weights of a primary (an implied common for each)
  local function list_of(p) return sec_ter[p] or {COMMON_SEC_AND_TER} end

  function R.first_primary() return primaries[1] end
  function R.first_secondary_ce() return {0, floor(secondary_ces[1] / 0x10000), secondary_ces[1] % 0x10000} end
  function R.last_secondary_ce()
    local st = secondary_ces[#secondary_ces]
    return {0, floor(st / 0x10000), st % 0x10000}
  end
  function R.first_tertiary_ce() return {0, 0, tertiary_ces[1]} end
  function R.last_tertiary_ce() return {0, 0, tertiary_ces[#tertiary_ces]} end

  function R.primary_after(p)
    local candidate = primaries[upper_bound(primaries, p)] or 0xFFFFFFFF
    local _, han = implicit.han_neighbors(p, han_ranges)
    if han and han < candidate then candidate = han end
    return candidate
  end
  function R.primary_before(p)
    local candidate = primaries[upper_bound(primaries, p - 1) - 1] or 0
    local han = implicit.han_neighbors(p, han_ranges)
    if han and han > candidate and han < p then candidate = han end
    return candidate
  end
  function R.secondary_after(p, s)
    local list = p == 0 and secondary_ces or list_of(p)
    for _, st in ipairs(list) do
      local sec = floor(st / 0x10000)
      if sec > s then return sec end
    end
    return p == 0 and 0x10000 or R.secondary_boundary
  end
  function R.tertiary_after(p, s, t)
    if p == 0 and s == 0 then
      for _, ter in ipairs(tertiary_ces) do if ter > t then return ter end end
      return 0x4000
    end
    local list = p == 0 and secondary_ces or list_of(p)
    local st = s * 0x10000 + t
    for _, v in ipairs(list) do
      if v > st then
        if floor(v / 0x10000) == s then return v % 0x10000 end
        return R.tertiary_boundary
      end
    end
    return R.tertiary_boundary
  end
  function R.secondary_before(p, s)
    local previous, list
    if p == 0 then
      previous, list = 0, secondary_ces
    else
      previous, list = BEFORE_WEIGHT16, list_of(p)
    end
    for _, st in ipairs(list) do
      local sec = floor(st / 0x10000)
      if sec >= s then break end
      previous = sec
    end
    return previous
  end
  function R.tertiary_before(p, s, t)
    if p == 0 and s == 0 then
      local previous = 0
      for _, ter in ipairs(tertiary_ces) do
        if ter >= t then break end
        previous = ter
      end
      return previous
    end
    local list = p == 0 and secondary_ces or list_of(p)
    local previous = BEFORE_WEIGHT16
    local st = s * 0x10000 + t
    for _, v in ipairs(list) do
      if v >= st then break end
      if floor(v / 0x10000) == s then previous = v % 0x10000 end
    end
    return previous
  end
  -- the last root CE with a primary before p, the first with a primary of
  -- at least p
  function R.last_ce_with_primary_before(p)
    local q = R.primary_before(p)
    local list = list_of(q)
    local st = list[#list]
    return {q, floor(st / 0x10000), st % 0x10000}
  end
  function R.first_ce_with_primary_at_least(p)
    local q = (sec_ter[p] or is_han(p)) and p or R.primary_after(p)
    return {q, COMMON_WEIGHT16, COMMON_WEIGHT16}
  end
  return R
end

-- shared by the collators of a root (and Han order)
local root_elements_cache = setmetatable({}, {__mode = "k"})
function M.root_elements(root_codes, root_info, implicit, han_ranges)
  local cache = root_elements_cache[root_codes]
  if not cache then
    cache = setmetatable({}, {__mode = "k"})
    root_elements_cache[root_codes] = cache
  end
  local R = cache[han_ranges]
  if not R then
    R = new_root_elements(root_codes, root_info, implicit, han_ranges)
    cache[han_ranges] = R
  end
  return R
end

---------------------------------------------------------------------------
-- CollationBuilder
---------------------------------------------------------------------------

-- temporary CEs point to nodes; real CEs are {p, s, t, case =, quaternary =}
local function ce_strength(ce)
  if ce.temp then return ce.temp_strength end
  if ce[1] ~= 0 then return PRIMARY end
  if ce[2] ~= 0 then return SECONDARY end
  if ce[3] ~= 0 then return TERTIARY end
  return IDENTICAL
end
local function temp_ce(index, strength) return {temp = index, temp_strength = strength} end
local function copy_ce(ce)
  if ce.temp then return {temp = ce.temp, temp_strength = ce.temp_strength, case = ce.case} end
  return {ce[1], ce[2], ce[3], case = ce.case, quaternary = ce.quaternary, han = ce.han}
end

local function is_jamo_l(c) return c >= 0x1100 and c <= 0x1112 end
local function is_jamo_v(c) return c >= 0x1161 and c <= 0x1175 end

function M.build(collator, items, deps)
  local implicit, root_info = deps.implicit, deps.root_info
  local root = M.root_elements(collator.root_codes, root_info, implicit, deps.han_ranges)

  -- nodes: weight (32 bits for primaries, 16 bits otherwise), strength,
  -- tailored, before2, before3, previous, next (indexes, 0 for none)
  local nodes = {}
  -- the indexes of the root primary nodes, in primary order
  local root_primary_indexes = {}
  local ces = {}

  local function insert_node_between(index, next_index, node)
    local new_index = #nodes + 1
    node.previous, node.next = index, next_index
    nodes[new_index] = node
    nodes[index].next = new_index
    if next_index ~= 0 then nodes[next_index].previous = new_index end
    return new_index
  end

  local function find_or_insert_node_for_primary(p)
    local low, high = 1, #root_primary_indexes
    while low <= high do
      local mid = floor((low + high) / 2)
      local q = nodes[root_primary_indexes[mid]].weight
      if q == p then return root_primary_indexes[mid] end
      if q < p then low = mid + 1 else high = mid - 1 end
    end
    local index = #nodes + 1
    nodes[index] = {weight = p, strength = PRIMARY, previous = 0, next = 0}
    table.insert(root_primary_indexes, low, index)
    return index
  end

  -- the explicit common node, when the node has nodes with weights before
  -- the common one
  local function find_common_node(index, strength)
    local node = nodes[index]
    if node.strength >= strength then return index end
    if (strength == SECONDARY and not node.before2) or (strength == TERTIARY and not node.before3) then
      return index
    end
    index = node.next
    node = nodes[index]
    repeat
      index = node.next
      node = nodes[index]
    until not (node.tailored or node.strength > strength or node.weight < COMMON_WEIGHT16)
    return index
  end

  local function find_or_insert_weak_node(index, weight16, level)
    if weight16 == COMMON_WEIGHT16 then return find_common_node(index, level) end
    local node = nodes[index]
    if weight16 ~= 0 and weight16 < COMMON_WEIGHT16 then
      local has_before = level == SECONDARY and "before2" or "before3"
      if not node[has_before] then
        -- the parent node has an implied common weight
        local common_node = {weight = COMMON_WEIGHT16, strength = level}
        if level == SECONDARY then
          common_node.before3 = node.before3
          node.before3 = nil
        end
        node[has_before] = true
        local next_index = node.next
        index = insert_node_between(index, next_index, {weight = weight16, strength = level})
        insert_node_between(index, next_index, common_node)
        return index
      end
    end
    local next_index = node.next
    while next_index ~= 0 do
      node = nodes[next_index]
      local next_strength = node.strength
      if next_strength <= level then
        if next_strength < level then break end
        if not node.tailored then
          if node.weight == weight16 then return next_index end
          if node.weight > weight16 then break end
        end
      end
      index = next_index
      next_index = node.next
    end
    return insert_node_between(index, next_index, {weight = weight16, strength = level})
  end

  local function find_or_insert_node_for_root_ce(ce, strength)
    local index = find_or_insert_node_for_primary(ce[1])
    if strength >= SECONDARY then
      index = find_or_insert_weak_node(index, ce[2], SECONDARY)
      if strength >= TERTIARY then
        index = find_or_insert_weak_node(index, ce[3], TERTIARY)
      end
    end
    return index
  end

  local function find_or_insert_node_for_ces(strength)
    local ce
    while true do
      if #ces == 0 then
        ce = {0, 0, 0}
        ces[1] = ce
        break
      end
      ce = ces[#ces]
      if ce_strength(ce) <= strength then break end
      ces[#ces] = nil
    end
    if ce.temp then return ce.temp end
    if floor(ce[1] / 0x1000000) == root.unassigned_lead then
      fail("tailoring relative to an unassigned code point not supported")
    end
    return find_or_insert_node_for_root_ce(ce, strength)
  end

  local function insert_tailored_node_after(index, strength)
    if strength >= SECONDARY then
      index = find_common_node(index, SECONDARY)
      if strength >= TERTIARY then index = find_common_node(index, TERTIARY) end
    end
    local node = nodes[index]
    local next_index = node.next
    while next_index ~= 0 do
      node = nodes[next_index]
      if node.strength <= strength then break end
      index = next_index
      next_index = node.next
    end
    return insert_node_between(index, next_index, {tailored = true, strength = strength})
  end

  local function get_weight16_before(index, node, level)
    local t
    if node.strength == TERTIARY then t = node.weight else t = COMMON_WEIGHT16 end
    while node.strength > SECONDARY do
      index = node.previous
      node = nodes[index]
    end
    if node.tailored then return BEFORE_WEIGHT16 end
    local s
    if node.strength == SECONDARY then s = node.weight else s = COMMON_WEIGHT16 end
    while node.strength > PRIMARY do
      index = node.previous
      node = nodes[index]
    end
    if node.tailored then return BEFORE_WEIGHT16 end
    local p = node.weight
    if level == SECONDARY then return root.secondary_before(p, s) end
    return root.tertiary_before(p, s, t)
  end

  local function special_reset_position(position)
    local ce
    local strength = PRIMARY
    local is_boundary = false
    if position == "first tertiary ignorable" or position == "last tertiary ignorable" then
      return {0, 0, 0}
    elseif position == "first secondary ignorable" then
      -- a tailored tertiary node after [0, 0, 0]
      local index = find_or_insert_node_for_root_ce({0, 0, 0}, TERTIARY)
      index = nodes[index].next
      if index ~= 0 then
        local node = nodes[index]
        if node.tailored and node.strength == TERTIARY then return temp_ce(index, TERTIARY) end
      end
      return root.first_tertiary_ce()
    elseif position == "last secondary ignorable" then
      ce, strength = root.last_tertiary_ce(), TERTIARY
    elseif position == "first primary ignorable" then
      -- a tailored secondary node after [0, 0, *]
      local index = find_or_insert_node_for_root_ce({0, 0, 0}, SECONDARY)
      local node = nodes[index]
      while true do
        index = node.next
        if index == 0 then break end
        node = nodes[index]
        strength = node.strength
        if strength < SECONDARY then break end
        if strength == SECONDARY then
          if node.tailored then
            if node.before3 then index = nodes[nodes[index].next].next end
            return temp_ce(index, SECONDARY)
          end
          break
        end
      end
      ce, strength = root.first_secondary_ce(), SECONDARY
    elseif position == "last primary ignorable" then
      ce, strength = root.last_secondary_ce(), SECONDARY
    elseif position == "first variable" then
      ce = {root.first_primary(), COMMON_WEIGHT16, COMMON_WEIGHT16}
      is_boundary = true
    elseif position == "last variable" then
      ce = root.last_ce_with_primary_before(root.variable_top + 1)
    elseif position == "first regular" then
      ce = root.first_ce_with_primary_at_least(root.variable_top + 1)
      is_boundary = true
    elseif position == "last regular" then
      -- the Han first primary, as ICU, for backward compatibility
      ce = root.first_ce_with_primary_at_least(deps.han_group_start)
    elseif position == "first implicit" then
      ce = {implicit.han_primary(0x4E00, deps.han_ranges), COMMON_WEIGHT16, COMMON_WEIGHT16}
    elseif position == "last implicit" then
      fail("reset to [last implicit] not supported")
    elseif position == "first trailing" then
      ce = {root.first_trailing_primary, COMMON_WEIGHT16, COMMON_WEIGHT16}
      is_boundary = true
    elseif position == "last trailing" then
      fail("LDML forbids tailoring to U+FFFF")
    end

    local index = find_or_insert_node_for_root_ce(ce, strength)
    local node = nodes[index]
    if position:match("^first ") then
      if not (node.before2 or node.before3) and is_boundary then
        -- a group's first primary boundary: the first character tailored
        -- after it, or the first real root CE after it
        index = node.next
        if index ~= 0 then
          node = nodes[index]
          ce = temp_ce(index, strength)
        else
          ce = {root.primary_after(ce[1]), COMMON_WEIGHT16, COMMON_WEIGHT16}
          index = find_or_insert_node_for_root_ce(ce, PRIMARY)
          node = nodes[index]
        end
      end
      if node.before2 or node.before3 then
        -- the first node tailored before this one at a weaker strength
        if node.before2 then
          index = nodes[nodes[index].next].next
          node = nodes[index]
        end
        if node.before3 then index = nodes[nodes[index].next].next end
        ce = temp_ce(index, strength)
      end
    else
      -- the last node tailored after the position, at a strength no
      -- greater than the position's
      while true do
        local next_index = node.next
        if next_index == 0 then break end
        local next_node = nodes[next_index]
        if next_node.strength < strength then break end
        index, node = next_index, next_node
      end
      if node.tailored then ce = temp_ce(index, strength) end
    end
    return ce
  end

  local function normalized(codepoints)
    return collator:string_to_codepoints(utf8.char(unpack(codepoints)))
  end
  -- the current CEs of a string: copies of the collator's (some temporary)
  local function get_ces(codepoints, list)
    list = list or {}
    local pos = 1
    while pos do
      local value
      value, pos = collator:get_weights(codepoints, pos)
      for _, ce in ipairs(value) do list[#list + 1] = copy_ce(ce) end
    end
    return list
  end

  local function add_reset(strength, item)
    if item.position then
      ces = {special_reset_position(item.position)}
    else
      ces = get_ces(normalized(item.string))
    end
    if strength == IDENTICAL then return end
    -- &[before strength]position
    local index = find_or_insert_node_for_ces(strength)
    local node = nodes[index]
    -- skip backwards over weaker nodes
    while node.strength > strength do
      index = node.previous
      node = nodes[index]
    end
    if node.strength == strength and node.tailored then
      -- just before this same-strength tailored node
      index = node.previous
    elseif strength == PRIMARY then
      local p = node.weight
      if p == 0 then fail("reset primary-before ignorable not possible") end
      if p <= root.first_primary() then fail("reset primary-before first non-ignorable not supported") end
      if p == root.first_trailing_primary then fail("reset primary-before [first trailing] not supported") end
      p = root.primary_before(p)
      index = find_or_insert_node_for_primary(p)
      -- after the last node between adjacent root nodes
      while true do
        node = nodes[index]
        local next_index = node.next
        if next_index == 0 then break end
        index = next_index
      end
    else
      -- &[before 2] or &[before 3]
      index = find_common_node(index, SECONDARY)
      if strength >= TERTIARY then index = find_common_node(index, TERTIARY) end
      node = nodes[index]
      if node.strength == strength then
        -- a same-strength node with an explicit weight
        local weight16 = node.weight
        if weight16 == 0 then
          if strength == SECONDARY then fail("reset secondary-before secondary ignorable not possible") end
          fail("reset tertiary-before completely ignorable not possible")
        end
        weight16 = get_weight16_before(index, node, strength)
        local previous_weight16
        local previous_index = node.previous
        local i = previous_index
        while true do
          node = nodes[i]
          local previous_strength = node.strength
          if previous_strength < strength then
            previous_weight16 = COMMON_WEIGHT16
            break
          elseif previous_strength == strength and not node.tailored then
            previous_weight16 = node.weight
            break
          end
          i = node.previous
        end
        if previous_weight16 == weight16 then
          index = previous_index
        else
          index = insert_node_between(previous_index, index, {weight = weight16, strength = strength})
        end
      else
        -- a stronger node with implied strength-common weight
        local weight16 = get_weight16_before(index, node, strength)
        index = find_or_insert_weak_node(index, weight16, strength)
      end
      strength = ce_strength(ces[#ces])
    end
    ces[#ces] = temp_ce(index, strength)
  end

  -- the case bits of a tailored string from its root CEs (setCaseBits)
  local function set_case_bits(nfd_string)
    local tailored_primaries = 0
    for _, ce in ipairs(ces) do
      if ce_strength(ce) == PRIMARY then tailored_primaries = tailored_primaries + 1 end
    end
    local cases = {}
    if tailored_primaries > 0 then
      local base_primaries = 0
      local last_case = 0
      for _, ce in ipairs(collator:root_weights(nfd_string)) do
        if ce[1] ~= 0 then
          base_primaries = base_primaries + 1
          local c = ce.case or 0
          if base_primaries < tailored_primaries then
            cases[base_primaries] = c
          elseif base_primaries == tailored_primaries then
            last_case = c
          elseif c ~= last_case then
            last_case = 1
            break
          end
        end
      end
      if base_primaries >= tailored_primaries then cases[tailored_primaries] = last_case end
    end
    local k = 0
    for _, ce in ipairs(ces) do
      local strength = ce_strength(ce)
      local case = 0
      if strength == PRIMARY then
        k = k + 1
        case = cases[k] or 0
      elseif strength == TERTIARY then
        -- tertiary CEs must have uppercase bits
        case = 2
      end
      ce.case = case ~= 0 and case or nil
    end
  end

  local written = {}
  local function add_relation(strength, item)
    local nfd_prefix = item.prefix and normalized(item.prefix)
    local nfd_string = normalized(item.string)
    local n = #nfd_string
    if n >= 2 then
      local c = nfd_string[1]
      if is_jamo_l(c) or is_jamo_v(c) then
        fail("contractions starting with conjoining Jamo L or V not supported")
      end
      c = nfd_string[n]
      if is_jamo_l(c) or (is_jamo_v(c) and is_jamo_l(nfd_string[n - 1])) then
        fail("contractions ending with conjoining Jamo L or L+V not supported")
      end
    end
    if strength ~= IDENTICAL then
      local index = find_or_insert_node_for_ces(strength)
      local ce = ces[#ces]
      if strength == PRIMARY and not ce.temp and ce[1] == 0 then
        fail("tailoring primary after ignorables not supported")
      end
      if strength == QUATERNARY and not ce.temp and ce[1] == 0 and ce[2] == 0 and ce[3] == 0 then
        fail("tailoring quaternary after tertiary ignorables not supported")
      end
      index = insert_tailored_node_after(index, strength)
      -- the new relation may yield a stronger CE but not a weaker one
      local temp_strength = ce_strength(ce)
      if strength < temp_strength then temp_strength = strength end
      ces[#ces] = temp_ce(index, temp_strength)
    end
    set_case_bits(nfd_string)
    local value = {}
    for _, ce in ipairs(ces) do value[#value + 1] = copy_ce(ce) end
    if item.extension then
      -- not modified, not even their case bits; not kept for the next
      -- relations
      get_ces(normalized(item.extension), value)
    end
    local key = nfd_string
    if nfd_prefix then
      -- a prefix mapping p|x as the contraction px: CE(p) followed by the
      -- CEs of x after p
      local prefix_ces = get_ces(nfd_prefix)
      key = {}
      for _, c in ipairs(nfd_prefix) do key[#key + 1] = c end
      for _, c in ipairs(nfd_string) do key[#key + 1] = c end
      for j = #prefix_ces, 1, -1 do table.insert(value, 1, prefix_ces[j]) end
    end
    collator:update_codes(key, value)
    for _, ce in ipairs(value) do written[#written + 1] = ce end
  end

  local function suppress_contractions(set)
    for code in pairs(set) do
      local entry = collator.codes[code]
      if entry and entry.children then
        for k, child in pairs(entry.children) do
          if not child.prefix then entry.children[k] = nil end
        end
        if next(entry.children) == nil then entry.children = nil end
      end
    end
    for _, entry in pairs(collator.codes) do
      for k, child in pairs(entry.children or {}) do
        if child.prefix and set[k] then entry.children[k] = nil end
      end
    end
  end

  for _, item in ipairs(items) do
    if item.kind == "reset" then
      add_reset(item.before or IDENTICAL, item)
    elseif item.kind == "relation" then
      add_relation(item.strength == "=" and IDENTICAL or item.strength, item)
    elseif item.kind == "setting" and item.name == "suppressContractions" then
      suppress_contractions(item.value)
    end
  end

  -- makeTailoredCEs: the weights of the tailored nodes
  local function count_tailored_nodes(i, strength)
    local count = 0
    while i ~= 0 do
      local node = nodes[i]
      if node.strength < strength then break end
      if node.strength == strength then
        if node.tailored then count = count + 1 else break end
      end
      i = node.next
    end
    return count
  end
  for _, i in ipairs(root_primary_indexes) do
    local node = nodes[i]
    local p = node.weight
    local s = p == 0 and 0 or COMMON_WEIGHT16
    local t = s
    local q = 0
    local p_tailored, s_tailored, t_tailored = false, false, false
    local primaries, secondaries, tertiaries
    local next_index = node.next
    while next_index ~= 0 do
      i = next_index
      node = nodes[i]
      next_index = node.next
      local strength = node.strength
      if strength == QUATERNARY then
        if q == 3 then fail("quaternary tailoring gap too small") end
        q = q + 1
      else
        if strength == TERTIARY then
          if node.tailored then
            if not t_tailored then
              local count = count_tailored_nodes(next_index, TERTIARY) + 1
              local limit
              if t == 0 then
                -- the gap at the beginning of the tertiary CE range
                t = root.tertiary_boundary - 0x100
                limit = root.first_tertiary_ce()[3]
              elseif not p_tailored and not s_tailored then
                limit = root.tertiary_after(p, s, t)
              elseif t == BEFORE_WEIGHT16 then
                limit = COMMON_WEIGHT16
              else
                limit = root.tertiary_boundary
              end
              tertiaries = tertiary_weights()
              if not tertiaries.alloc(t, limit, count) then fail("tertiary tailoring gap too small") end
              t_tailored = true
            end
            t = tertiaries.next_weight()
          else
            t = node.weight
            t_tailored = false
          end
        else
          if strength == SECONDARY then
            if node.tailored then
              if not s_tailored then
                local count = count_tailored_nodes(next_index, SECONDARY) + 1
                local limit
                if s == 0 then
                  -- the gap at the beginning of the secondary CE range
                  s = root.secondary_boundary - 0x100
                  limit = root.first_secondary_ce()[2]
                elseif not p_tailored then
                  limit = root.secondary_after(p, s)
                elseif s == BEFORE_WEIGHT16 then
                  limit = COMMON_WEIGHT16
                else
                  limit = root.secondary_boundary
                end
                if s == COMMON_WEIGHT16 then
                  -- not into the range of compressed common secondaries
                  s = root.last_common_secondary
                end
                secondaries = secondary_weights()
                if not secondaries.alloc(s, limit, count) then fail("secondary tailoring gap too small") end
                s_tailored = true
              end
              s = secondaries.next_weight()
            else
              s = node.weight
              s_tailored = false
            end
          else
            if not p_tailored then
              local count = count_tailored_nodes(next_index, PRIMARY) + 1
              local limit = root.primary_after(p)
              primaries = primary_weights(root.is_compressible(p))
              if not primaries.alloc(p, limit, count) then fail("primary tailoring gap too small") end
              p_tailored = true
            end
            p = primaries.next_weight()
            s = COMMON_WEIGHT16
            s_tailored = false
          end
          t = s == 0 and 0 or COMMON_WEIGHT16
          t_tailored = false
        end
        q = 0
      end
      if node.tailored then node.ce = {p, s, t, quaternary = q ~= 0 and q or nil} end
    end
  end

  -- finalizeCEs: the temporary CEs become the weights of their nodes, with
  -- their case bits
  for _, ce in ipairs(written) do
    if ce.temp then
      local final = nodes[ce.temp].ce
      ce[1], ce[2], ce[3], ce.quaternary = final[1], final[2], final[3], final.quaternary
      ce.temp, ce.temp_strength = nil, nil
    end
  end
  rawset(collator, "stringcache", {})
  rawset(collator, "weight_to_char", nil)
end

return M
