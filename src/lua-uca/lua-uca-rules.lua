-- parser of the CLDR collation rule syntax (UTS #35, Collation Rule Syntax),
-- following ICU's CollationRuleParser (collationruleparser.cpp)
-- rules.parse(text, checks) returns a list of items:
--   {kind = "setting", name = name, value = value}
--   {kind = "reset", before = 1 | 2 | 3 | nil, position = name | nil,
--    string = codepoints | nil}
--   {kind = "relation", strength = 1 | 2 | 3 | 4 | "=", string = codepoints,
--    prefix = codepoints | nil, extension = codepoints | nil}
-- starred relations (<*, =*, ...) are expanded into one relation for each
-- character; checks (optional) has the functions boundary(c) (c starts an
-- NFC boundary) and inert(c) (c is NFD-inert), for the checks of prefixes
-- and starred relations
-- rules.unescape(text) unescapes \u, \U, \x and the other escapes, as ICU's
-- tools do for the rules of its data (u_unescape)
local utf8 = utf8 or require "lua-utf8"

local M = {}

local function parse_error(message)
  error("lua-uca: collation rules: " .. message, 0)
end

-- u_unescapeAt: \uhhhh, \Uhhhhhhhh, \x{h...}, \xhh, \ooo, \cX, the C escapes
-- a b e f n r t v, and \ followed by any other character for that character
local c_escapes = {a = 7, b = 8, e = 0x1B, f = 0x0C, n = 0x0A, r = 0x0D, t = 0x09, v = 0x0B}

function M.unescape(text)
  local out = {}
  local i, length = 1, #text
  local pending_high
  local function put(code)
    if pending_high then
      if code >= 0xDC00 and code <= 0xDFFF then
        code = 0x10000 + (pending_high - 0xD800) * 0x400 + (code - 0xDC00)
        pending_high = nil
      else
        out[#out + 1] = utf8.char(pending_high)
        pending_high = nil
      end
    end
    if code >= 0xD800 and code <= 0xDBFF then
      pending_high = code
    else
      out[#out + 1] = utf8.char(code)
    end
  end
  while i <= length do
    local byte = text:sub(i, i)
    if byte ~= "\\" then
      if pending_high then out[#out + 1] = utf8.char(pending_high); pending_high = nil end
      out[#out + 1] = byte
      i = i + 1
    else
      local c = text:sub(i + 1, i + 1)
      local hex
      if c == "u" then
        hex = text:match("^%x%x%x%x", i + 2)
        if hex then i = i + 6 end
      elseif c == "U" then
        hex = text:match("^%x%x%x%x%x%x%x%x", i + 2)
        if hex then i = i + 10 end
      elseif c == "x" and text:sub(i + 2, i + 2) == "{" then
        hex = text:match("^(%x%x?%x?%x?%x?%x?%x?%x?)}", i + 3)
        if hex then i = i + 3 + #hex + 1 end
      elseif c == "x" then
        hex = text:match("^%x%x?", i + 2)
        if hex then i = i + 2 + #hex end
      end
      if hex then
        put(tonumber(hex, 16))
      elseif c:match("^[0-7]$") then
        local octal = text:match("^[0-7][0-7]?[0-7]?", i + 1)
        put(tonumber(octal, 8))
        i = i + 1 + #octal
      elseif c_escapes[c] then
        put(c_escapes[c])
        i = i + 2
      elseif c == "c" and i + 2 <= length then
        put(text:byte(i + 2) % 32)
        i = i + 3
      elseif c ~= "" then
        -- the escaped character itself (possibly more than one byte)
        local lead = text:byte(i + 1)
        local n = lead < 0xC0 and 1 or lead < 0xE0 and 2 or lead < 0xF0 and 3 or 4
        if pending_high then out[#out + 1] = utf8.char(pending_high); pending_high = nil end
        out[#out + 1] = text:sub(i + 1, i + n)
        i = i + 1 + n
      else
        parse_error("backslash escape at the end of the rule string")
      end
    end
  end
  if pending_high then out[#out + 1] = utf8.char(pending_high) end
  return table.concat(out)
end

-- PatternProps::isWhiteSpace
local white_space = {[0x09] = true, [0x0A] = true, [0x0B] = true, [0x0C] = true, [0x0D] = true,
  [0x20] = true, [0x85] = true, [0x200E] = true, [0x200F] = true, [0x2028] = true, [0x2029] = true}
-- the ends of a comment
local line_end = {[0x0A] = true, [0x0C] = true, [0x0D] = true, [0x85] = true, [0x2028] = true, [0x2029] = true}

-- the ASCII punctuation and symbols are syntax characters
local function is_syntax(c)
  return c >= 0x21 and c <= 0x7E and (c <= 0x2F or (c >= 0x3A and c <= 0x40) or (c >= 0x5B and c <= 0x60) or c >= 0x7B)
end

local positions = {
  ["first tertiary ignorable"] = true, ["last tertiary ignorable"] = true,
  ["first secondary ignorable"] = true, ["last secondary ignorable"] = true,
  ["first primary ignorable"] = true, ["last primary ignorable"] = true,
  ["first variable"] = true, ["last variable"] = true,
  ["first regular"] = true, ["last regular"] = true,
  ["first implicit"] = true, ["last implicit"] = true,
  ["first trailing"] = true, ["last trailing"] = true,
  -- older names
  ["top"] = "last regular", ["variable top"] = "last variable",
}

local on_off = {on = true, off = false}
local settings = {
  strength = function(v)
    if v:match("^[1-4]$") then return tonumber(v) end
    if v == "I" then return "I" end
  end,
  alternate = function(v) if v == "non-ignorable" or v == "shifted" then return v end end,
  maxVariable = function(v)
    if v == "space" or v == "punct" or v == "symbol" or v == "currency" then return v end
  end,
  caseFirst = function(v) if v == "off" or v == "lower" or v == "upper" then return v end end,
  caseLevel = function(v) return on_off[v] end,
  normalization = function(v) return on_off[v] end,
  numericOrdering = function(v) return on_off[v] end,
  hiraganaQ = function(v)
    if v == "on" then parse_error("[hiraganaQ on] is not supported") end
    return on_off[v]
  end,
  import = function(v) if v ~= "" then return v end end,
}

-- a UnicodeSet pattern: only characters and ranges ([abc], [a-z], with
-- white space), as in CLDR's rules
-- TODO: ICU's full UnicodeSet syntax (nested sets, &, -, ^, {strings},
-- properties such as [:Thai:] and \p{gc=Lo}), through lua-transforms (its
-- set parser and property data) as an optional dependency once it is
-- released
local function unicode_set(cps)
  local set = {}
  local i = 2
  local n = #cps - 1
  while i <= n do
    local c = cps[i]
    if c == 0x5B or c == 0x5D or c == 0x5C or c == 0x7B or c == 0x24 or c == 0x26 or c == 0x5E then
      parse_error("only characters and ranges are supported in sets")
    end
    if white_space[c] then
      i = i + 1
    elseif cps[i + 1] == 0x2D and i + 2 <= n then
      for code = c, cps[i + 2] do set[code] = true end
      i = i + 3
    else
      set[c] = true
      i = i + 1
    end
  end
  return set
end

function M.parse(text, checks)
  checks = checks or {}
  local rules = {}
  for _, code in utf8.codes(text) do rules[#rules + 1] = code end
  local length = #rules
  local i = 1
  local items = {}

  local function skip_white_space(j)
    while j <= length and white_space[rules[j]] do j = j + 1 end
    return j
  end
  local function skip_comment(j)
    while j <= length do
      local c = rules[j]
      j = j + 1
      if line_end[c] then break end
    end
    return j
  end

  -- CollationRuleParser::parseString
  local function parse_string(j)
    local raw = {}
    while j <= length do
      local c = rules[j]
      j = j + 1
      if is_syntax(c) then
        if c == 0x27 then
          if rules[j] == 0x27 then
            raw[#raw + 1] = 0x27
            j = j + 1
          else
            while true do
              if j > length then parse_error("quoted literal text missing terminating apostrophe") end
              c = rules[j]
              j = j + 1
              if c == 0x27 then
                if rules[j] == 0x27 then
                  j = j + 1
                else
                  break
                end
              end
              raw[#raw + 1] = c
            end
          end
        elseif c == 0x5C then
          if j > length then parse_error("backslash escape at the end of the rule string") end
          raw[#raw + 1] = rules[j]
          j = j + 1
        else
          j = j - 1
          break
        end
      elseif white_space[c] then
        j = j - 1
        break
      else
        raw[#raw + 1] = c
      end
    end
    for _, c in ipairs(raw) do
      if c >= 0xD800 and c <= 0xDFFF then parse_error("string contains an unpaired surrogate") end
      if c >= 0xFFFD and c <= 0xFFFF then parse_error("string contains U+FFFD, U+FFFE or U+FFFF") end
    end
    return raw, j
  end
  local function parse_tailoring_string(j)
    local raw
    raw, j = parse_string(skip_white_space(j))
    if #raw == 0 then parse_error("missing relation string") end
    return raw, skip_white_space(j)
  end

  -- words up to a syntax character other than - and _, white space as one
  -- space (CollationRuleParser::readWords)
  local function read_words(j)
    local raw = {}
    j = skip_white_space(j)
    while true do
      if j > length then return nil end
      local c = rules[j]
      if is_syntax(c) and c ~= 0x2D and c ~= 0x5F then
        if raw[#raw] == 0x20 then raw[#raw] = nil end
        local t = {}
        for k, code in ipairs(raw) do t[k] = utf8.char(code) end
        return table.concat(t), j
      end
      if white_space[c] then
        raw[#raw + 1] = 0x20
        j = skip_white_space(j + 1)
      else
        raw[#raw + 1] = c
        j = j + 1
      end
    end
  end

  local function parse_special_position(j)
    local raw, k = read_words(j + 1)
    if raw and raw ~= "" and rules[k] == 0x5D then
      local known = positions[raw]
      if known then return known == true and raw or known, k + 1 end
    end
    parse_error("not a valid special reset position")
  end

  local function parse_reset_and_position()
    local j = skip_white_space(i + 1)
    local before
    local raw, k = read_words(j + 1)
    if rules[j] == 0x5B and raw and raw:match("^before [123]$") and rules[k] == 0x5D then
      before = tonumber(raw:sub(-1))
      j = skip_white_space(k + 1)
    end
    if j > length then parse_error("reset without position") end
    local reset = {kind = "reset", before = before}
    if rules[j] == 0x5B then
      reset.position, j = parse_special_position(j)
    else
      reset.string, j = parse_tailoring_string(j)
    end
    items[#items + 1] = reset
    i = j
    return before
  end

  -- returns strength (1 to 4, "="), starred, the length of the operator
  local function parse_relation_operator()
    i = skip_white_space(i)
    if i > length then return nil end
    local j = i
    local c = rules[j]
    j = j + 1
    local strength, star
    if c == 0x3C then
      strength = 1
      while strength < 4 and rules[j] == 0x3C do strength = strength + 1; j = j + 1 end
      if rules[j] == 0x2A then star = true; j = j + 1 end
    elseif c == 0x3B then
      strength = 2
    elseif c == 0x2C then
      strength = 3
    elseif c == 0x3D then
      strength = "="
      if rules[j] == 0x2A then star = true; j = j + 1 end
    else
      return nil
    end
    return strength, star, j - i
  end

  local function parse_relation_strings(strength, j)
    local prefix, str, extension
    str, j = parse_tailoring_string(j)
    if rules[j] == 0x7C then
      prefix = str
      str, j = parse_tailoring_string(j + 1)
    end
    if rules[j] == 0x2F then
      extension, j = parse_tailoring_string(j + 1)
    end
    if prefix and checks.boundary then
      if not checks.boundary(prefix[1]) or not checks.boundary(str[1]) then
        parse_error("in 'prefix|str', prefix and str must each start with an NFC boundary")
      end
    end
    items[#items + 1] = {kind = "relation", strength = strength, string = str, prefix = prefix, extension = extension}
    i = j
  end

  local function parse_starred_characters(strength, j)
    local raw
    raw, j = parse_string(skip_white_space(j))
    if #raw == 0 then parse_error("missing starred-relation string") end
    local previous
    local function add(c)
      items[#items + 1] = {kind = "relation", strength = strength, string = {c}}
    end
    local k = 1
    while true do
      while raw[k] do
        local c = raw[k]
        if checks.inert and not checks.inert(c) then parse_error("starred-relation string is not all NFD-inert") end
        add(c)
        previous = c
        k = k + 1
      end
      if rules[j] ~= 0x2D then break end
      if not previous then parse_error("range without start in starred-relation string") end
      raw, j = parse_string(j + 1)
      if #raw == 0 then parse_error("range without end in starred-relation string") end
      local c = raw[1]
      if c < previous then parse_error("range start greater than end in starred-relation string") end
      for code = previous + 1, c do
        if checks.inert and not checks.inert(code) then parse_error("starred-relation string range is not all NFD-inert") end
        if code >= 0xD800 and code <= 0xDFFF then parse_error("starred-relation string range contains a surrogate") end
        if code >= 0xFFFD and code <= 0xFFFF then parse_error("starred-relation string range contains U+FFFD, U+FFFE or U+FFFF") end
        add(code)
      end
      previous = nil
      k = 2
    end
    i = skip_white_space(j)
  end

  local function parse_rule_chain()
    local before = parse_reset_and_position()
    local first = true
    while true do
      local strength, star, operator_length = parse_relation_operator()
      if not strength then
        if rules[i] == 0x23 then
          i = skip_comment(i + 1)
        else
          if first then parse_error("reset not followed by a relation") end
          return
        end
      else
        if before then
          local level = strength == "=" and 5 or strength
          if first then
            if level ~= before then parse_error("reset-before strength differs from its first relation") end
          elseif level < before then
            parse_error("reset-before strength followed by a stronger relation")
          end
        end
        if star then
          parse_starred_characters(strength, i + operator_length)
        else
          parse_relation_strings(strength, i + operator_length)
        end
        first = false
      end
    end
  end

  local function parse_setting()
    local raw, j = read_words(i + 1)
    if not raw or raw == "" then parse_error("expected a setting/option at '['") end
    if rules[j] == 0x5D then
      j = j + 1
      if raw == "reorder" or raw:match("^reorder ") then
        local codes = {}
        for code in raw:sub(8):gmatch("%S+") do codes[#codes + 1] = code end
        items[#items + 1] = {kind = "setting", name = "reorder", value = codes}
        i = j
        return
      end
      if raw == "backwards 2" then
        items[#items + 1] = {kind = "setting", name = "backwards", value = 2}
        i = j
        return
      end
      local name, value = raw:match("^(.-) (%S+)$")
      local check = name and settings[name]
      if check then
        local v = check(value)
        if v ~= nil then
          items[#items + 1] = {kind = "setting", name = name, value = v}
          i = j
          return
        end
      end
    elseif rules[j] == 0x5B and (raw == "optimize" or raw == "suppressContractions") then
      -- the set, from [ to the matching ], then the closing ]
      local level, k = 0, j
      local set = {}
      while true do
        if k > length then parse_error("unbalanced UnicodeSet pattern brackets") end
        local c = rules[k]
        set[#set + 1] = c
        k = k + 1
        if c == 0x5B then
          level = level + 1
        elseif c == 0x5D then
          level = level - 1
          if level == 0 then break end
        end
      end
      k = skip_white_space(k)
      if rules[k] ~= 0x5D then parse_error("missing option-terminating ']' after UnicodeSet pattern") end
      items[#items + 1] = {kind = "setting", name = raw, value = unicode_set(set)}
      i = k + 1
      return
    end
    parse_error("not a valid setting/option")
  end

  while i <= length do
    local c = rules[i]
    if white_space[c] then
      i = i + 1
    elseif c == 0x26 then
      parse_rule_chain()
    elseif c == 0x5B then
      parse_setting()
    elseif c == 0x23 then
      i = skip_comment(i + 1)
    elseif c == 0x40 then
      -- @ is [backwards 2]
      items[#items + 1] = {kind = "setting", name = "backwards", value = 2}
      i = i + 1
    elseif c == 0x21 then
      -- ! turned on Thai/Lao reversal, ignored (the root has contractions)
      i = i + 1
    else
      parse_error("expected a reset or setting or comment")
    end
  end
  return items
end

return M
