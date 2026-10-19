-- the collation rules of a locale, from CLDR's data (lua-uca-collations.lua),
-- found as in ICU (CollationLoader, the coll resource bundles): the locale,
-- then its parents (CLDR's parent locales of collations, otherwise the
-- locale without its last subtag), then the root; the requested type, or
-- the default one (the first <defaultCollation> found that way), then
-- "standard"
local data
if kpse then
  data = require "lua-uca.lua-uca-collations"
else
  data = require "lua-uca.collations"
end

local M = {}

-- the collation types of -u-co- that are not CLDR's names (bcp47/collation.xml)
local type_names = {dict = "dictionary", gb2312 = "gb2312han", phonebk = "phonebook", trad = "traditional"}

-- a locale from a language tag (BCP 47, also with _): language, script,
-- region and variants as in CLDR's file names, and the collation type of
-- -u-co-; und is the root
local function parse_tag(tag)
  local subtags = {}
  for subtag in tag:gmatch("[^%-_]+") do subtags[#subtags + 1] = subtag end
  local language = (subtags[1] or ""):lower()
  if not language:match("^%a%a%a?%a?%a?%a?%a?%a?$") then return nil end
  local script, region, variants, kind = nil, nil, {}, nil
  local i = 2
  if subtags[i] and subtags[i]:match("^%a%a%a%a$") then
    script = subtags[i]:sub(1, 1):upper() .. subtags[i]:sub(2):lower()
    i = i + 1
  end
  if subtags[i] and (subtags[i]:match("^%a%a$") or subtags[i]:match("^%d%d%d$")) then
    region = subtags[i]:upper()
    i = i + 1
  end
  while subtags[i] and #subtags[i] > 1 do
    variants[#variants + 1] = subtags[i]:upper()
    i = i + 1
  end
  -- the extensions: the keys of -u- (co: the collation type)
  local keys = {}
  while subtags[i] do
    local singleton = subtags[i]:lower()
    i = i + 1
    if singleton == "u" then
      -- the attributes before the first key are not used
      while subtags[i] and #subtags[i] > 2 do i = i + 1 end
      while subtags[i] and #subtags[i] == 2 do
        local name = subtags[i]:lower()
        local values = {}
        i = i + 1
        while subtags[i] and #subtags[i] > 2 do
          values[#values + 1] = subtags[i]:lower()
          i = i + 1
        end
        if not keys[name] then keys[name] = values end
      end
    else
      while subtags[i] and #subtags[i] > 1 do i = i + 1 end
    end
  end
  if keys.co then
    kind = table.concat(keys.co, "-")
    kind = type_names[kind] or kind
  end
  return language, script, region, variants, kind, keys
end

-- the collation keys of -u- as options (UTS #35, ICU's
-- CollationLoader::loadFromLocale); "true" is also given as an empty value
local on_off = {[""] = true, ["true"] = true, ["false"] = false}
local key_options = {
  ka = function(v) return "variable_weighting", ({noignore = "non-ignorable", shifted = "shifted"})[v] end,
  kb = function(v) return "accents_backward", on_off[v] end,
  kc = function(v) return "case_level", on_off[v] end,
  kf = function(v) return "case_first", ({upper = "upper", lower = "lower", ["false"] = "off"})[v] end,
  kn = function(v) return "numeric", on_off[v] end,
  kv = function(v) return "max_variable", ({space = true, punct = true, symbol = true, currency = true})[v] and v end,
  -- normalization: lua-uca normalizes when it can
  kk = function(v) return nil, on_off[v] end,
}
local strengths = {level1 = 1, level2 = 2, level3 = 3, level4 = 4, identic = 4}

-- the options and the reordering codes given by the -u- keys of a tag; an
-- error for a wrong value
function M.options(tag)
  local language, _, _, _, _, keys = parse_tag(tag)
  if not language then error("lua-uca: not a language tag: " .. tostring(tag), 2) end
  local options, reorder = {}, nil
  for name, values in pairs(keys) do
    local value = table.concat(values, "-")
    if key_options[name] then
      local option, setting = key_options[name](value)
      if setting == nil then error("lua-uca: wrong value of -u-" .. name .. "- in " .. tag, 2) end
      if option then options[option] = setting end
    elseif name == "ks" then
      if not strengths[value] then error("lua-uca: wrong value of -u-ks- in " .. tag, 2) end
      options.strength = strengths[value]
      options.identical_level = value == "identic"
    elseif name == "kr" then
      reorder = {}
      for _, code in ipairs(values) do reorder[#reorder + 1] = code end
    end
  end
  return options, reorder
end

-- the locales to look in: the locale and its parents, up to the root
local function chain(tag)
  local language, script, region, variants, kind = parse_tag(tag)
  if not language then return nil end
  local list = {}
  if language ~= "und" and language ~= "root" then
    -- the script of the region, for the languages with rules for more than
    -- one script (zh-TW is zh_Hant_TW); the default script is left out
    -- (zh-Hans-CN is zh_CN), as in ICU's aliases
    local scripts = data.scripts[language]
    if scripts then
      script = script or (region and scripts[region]) or scripts.default
      if script == scripts.default then script = nil end
    end
    local parts = {language}
    if script then parts[#parts + 1] = script end
    if region then parts[#parts + 1] = region end
    for _, variant in ipairs(variants) do parts[#parts + 1] = variant end
    local id = table.concat(parts, "_")
    while id and id ~= "root" do
      list[#list + 1] = id
      id = data.parents[id] or id:match("^(.+)_[^_]+$")
    end
  end
  list[#list + 1] = "root"
  return list, kind
end

-- the rules of the type kind (or the default type) for the language tag,
-- not the private types; nil and a message when there are none
function M.rules(tag, kind)
  local list, tag_kind = chain(tag)
  if not list then return nil, "not a language tag: " .. tostring(tag) end
  kind = kind or tag_kind
  if kind and kind:match("^private%-") then
    return nil, "the collation type " .. kind .. " is internal"
  end
  local default
  for _, id in ipairs(list) do
    local entry = data.locales[id]
    if entry and entry.default then
      default = entry.default
      break
    end
  end
  local function find(name)
    for _, id in ipairs(list) do
      local entry = data.locales[id]
      if entry and entry[name] and name ~= "default" then return entry[name] end
    end
  end
  local tried = {}
  for _, name in ipairs {kind or default, default, "standard"} do
    if not tried[name] then
      tried[name] = true
      local rules = find(name)
      if rules then return rules, name end
    end
  end
  return nil, "no collation rules for " .. tag
end

-- the rules of [import tag], as ICU's importer: the type of -u-co-, or
-- "standard" (not the default type), from the locale or its parents, also
-- the private ones; nil and a message when there are none
function M.import_rules(tag)
  local list, kind = chain(tag)
  if not list then return nil, "not a language tag: " .. tostring(tag) end
  kind = kind or "standard"
  for _, id in ipairs(list) do
    local entry = data.locales[id]
    if entry and entry[kind] and kind ~= "default" then return entry[kind] end
  end
  return nil, "no collation type " .. kind .. " for " .. tag
end

-- the locales with rules (the names of CLDR's files) and their types
function M.list()
  local list = {}
  for id, entry in pairs(data.locales) do
    local kinds = {}
    for name in pairs(entry) do
      if name ~= "default" and not name:match("^private%-") then kinds[#kinds + 1] = name end
    end
    table.sort(kinds)
    list[id] = kinds
  end
  return list
end

return M
