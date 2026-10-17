-- run ICU's collation tests (collationtest.txt, from ICU's test data):
-- tailoring rules and settings, then strings in order with the level of
-- each difference
-- texlua tools/collationtest.lua [data/collationtest.txt]
kpse.set_program_name "luatex"
-- use the files in src/, not the installed ones
table.insert(package.searchers, 2, function(name)
  local filename, err = package.searchpath(name, "src/?.lua")
  if filename then return assert(loadfile(filename)), filename end
  return err
end)
local root = require "lua-uca.lua-uca-root"
local collator = require "lua-uca.lua-uca-collator"
-- ICU's default strength is tertiary (lua-uca's default compares the
-- quaternary level with shifted variable weighting)
local function new_collator() return collator.new(root, {strength = 3}) end

local filename = arg[1] or "data/collationtest.txt"

-- ICU's escapes, as in the rule syntax
local unescape = require("lua-uca.lua-uca-rules").unescape

-- the settings of "% name=value"
local attributes = {
  strength = function(c, v)
    local values = {primary = 1, secondary = 2, tertiary = 3, quaternary = 4}
    if v == "identical" then
      c:set {strength = 4, identical_level = true}
    else
      c:set {strength = values[v], identical_level = false}
    end
  end,
  alternate = function(c, v) c:set {variable_weighting = v} end,
  backwards = function(c, v) c:set {accents_backward = v == "on"} end,
  caseFirst = function(c, v) c:set {case_first = v} end,
  caseLevel = function(c, v) c:set {case_level = v == "on"} end,
  maxVariable = function(c, v) c:set {max_variable = v} end,
  normalization = function() end,
}

-- the level of the first difference: the levels in the order of the sort
-- key, then the identical level
local function difference(c, a, b)
  local settings = c.settings
  local names = {"1"}
  if settings.strength ~= 1 then names[#names + 1] = "2" end
  if settings.case_level then names[#names + 1] = "c" end
  if settings.strength == nil or settings.strength >= 3 then names[#names + 1] = "3" end
  if settings.strength == 4 or (settings.strength == nil and settings.variable_weighting == "shifted") then
    names[#names + 1] = "4"
  end
  local level = 1
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      local name = names[level] or "i"
      if a[i] == nil then return "<", name end
      if b[i] == nil then return ">", name end
      return a[i] < b[i] and "<" or ">", name
    end
    if a[i] == 0 then level = level + 1 end
  end
  return "=", nil
end

local c, skip, test = nil, nil, ""
local blocks, passed, failed, skipped = 0, 0, 0, 0
local reasons = {}
local previous, previous_line
local lines = {}
for line in io.lines(filename) do lines[#lines + 1] = line end
local i = 1
local function skip_block(reason)
  skip = reason
  reasons[reason] = (reasons[reason] or 0) + 1
end
while i <= #lines do
  local line = lines[i]
  i = i + 1
  if line:match("^%*%* test:") then
    test = line:match("^%*%* test:%s*(.*)")
  elseif line:match("^@ root") then
    c, skip = new_collator(), nil
  elseif line:match("^@ locale") then
    c = nil
    skip_block("@ locale")
  elseif line:match("^@ rules") then
    local text = {}
    while lines[i] and not lines[i]:match("^[%*@%%]") do
      text[#text + 1] = lines[i]
      i = i + 1
    end
    c, skip = new_collator(), nil
    local ok, err = pcall(function()
      c:tailor_string(table.concat(text, "\n"))
      c:apply_rules()
    end)
    if not ok then
      c = nil
      skip_block(tostring(err):gsub("^.-lua%-uca: ", ""):gsub("%(.*", ""))
    end
  elseif line:match("^%% ") then
    if c then
      local name, value = line:match("^%%%s*(%S+)=(%S+)")
      local reorder = line:match("^%%%s*reorder%s+(.*)")
      if reorder then
        local codes = {}
        for code in reorder:gmatch("%S+") do codes[#codes + 1] = code end
        if codes[1] == "default" then codes = {"others"} end
        c:reorder(codes)
      elseif name and attributes[name] then
        attributes[name](c, value)
      else
        c = nil
        skip_block("% " .. (name or line))
      end
    end
  elseif line:match("^%* compare") then
    blocks = blocks + 1
    previous = nil
    while lines[i] and not lines[i]:match("^[%*@%%]") do
      local relation, text = lines[i]:match("^([<=][%w]?)%s+(.-)%s*$")
      if relation and c then
        text = unescape((text:gsub("%s+#.*$", "")))
        local key = c:make_sort_key(c:string_to_codepoints(text))
        if previous then
          local order, level = difference(c, previous, key)
          local expected_order = relation == "=" and "=" or "<"
          local expected_level = relation:match("^<(.)$")
          if order ~= expected_order or (expected_level and level ~= expected_level) then
            failed = failed + 1
            if failed <= 1000 then
              print(string.format("%s: %s %s expected %s, got %s%s", test, previous_line, text, relation, order, level or ""))
            end
          else
            passed = passed + 1
          end
        end
        previous, previous_line = key, text
      elseif relation then
        skipped = skipped + 1
      end
      i = i + 1
    end
  end
end
print(string.format("%d comparisons passed, %d failed, %d skipped", passed, failed, skipped))
local t = {}
for reason, n in pairs(reasons) do t[#t + 1] = string.format("%s (%d)", reason, n) end
table.sort(t)
print("skipped: " .. table.concat(t, ", "))
os.exit(failed == 0 and 0 or 1)
