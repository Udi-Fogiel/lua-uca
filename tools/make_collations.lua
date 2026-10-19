-- make the table of CLDR's collation rules (common/collation/*.xml) with the
-- data for finding a locale's rules: the parent locales (supplementalData.xml)
-- and the scripts of the languages with rules for more than one script
-- (likelySubtags.xml)
-- texlua tools/make_collations.lua > src/lua-uca/lua-uca-collations.lua
-- the collations are those of ICU's data (cldr-to-icu): approved or
-- contributed, not the alternative proposals; the short form of a rule set
-- (alt="short", the same order written with ranges) when there is one;
-- texlua, with lua-uni-normalize
-- the rules are written in NFC (CLDR's files are in NFD): the builder
-- normalizes them to NFD when it can (as ICU's), and without normalization
-- (LuaJITTeX) they match the NFC input
local dir = arg[1] or "data"
kpse.set_program_name "luatex"
local normalize = require "lua-uni-normalize"

local function read(filename)
  local file = assert(io.open(filename))
  local text = file:read("*a")
  file:close()
  return text
end

local function attribute(attributes, name)
  return attributes:match(name .. "%s*=%s*\"([^\"]*)\"") or attributes:match(name .. "%s*=%s*'([^']*)'")
end

local included_draft = {approved = true, contributed = true}

-- the files in the directory listing
local files = {}
local listing = io.popen("ls " .. dir .. "/collation")
for name in listing:lines() do
  if name:match("%.xml$") then files[#files + 1] = name end
end
listing:close()
table.sort(files)

-- the rules without the indentation of the XML file and the empty lines
local function clean(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" then lines[#lines + 1] = line end
  end
  return normalize.NFC(table.concat(lines, "\n"))
end

local locales = {}
local languages = {}
for _, name in ipairs(files) do
  local locale = name:gsub("%.xml$", "")
  local xml = read(dir .. "/collation/" .. name)
  local entry = {}
  local short = {}
  for attributes, body in xml:gmatch("<collation(%s[^>]*)>(.-)</collation%s*>") do
    local kind = assert(attribute(attributes, "type"), "collation without type in " .. name)
    local alt = attribute(attributes, "alt")
    local draft = attribute(attributes, "draft") or "approved"
    -- root's standard has no rules
    local text = body:match("<cr%s*><!%[CDATA%[(.-)%]%]></cr%s*>") or ""
    if included_draft[draft] and (not alt or alt == "short") then
      if alt == "short" then short[kind] = true end
      if alt == "short" or not short[kind] then entry[kind] = clean(text) end
    end
  end
  entry.default = xml:match("<defaultCollation>%s*([^<%s]+)%s*</defaultCollation>")
  if next(entry) then
    locales[locale] = entry
    languages[locale:match("^[^_]+")] = true
  end
end

-- the parent locales of collations: their own list replaces the general one
-- (UTS #35; in ICU's data zh_Hant falls back to zh, which has its default
-- type, stroke)
local parents = {}
local supplemental = read(dir .. "/supplementalData.xml")
for attributes, body in supplemental:gmatch("<parentLocales(%s*[^>]*)>(.-)</parentLocales>") do
  local component = attribute(attributes, "component")
  if component and component:match("collations") then
    for parent_attributes in body:gmatch("<parentLocale(%s[^>]*)/>") do
      local parent = attribute(parent_attributes, "parent")
      for child in attribute(parent_attributes, "locales"):gmatch("%S+") do
        parents[child] = parent
      end
    end
  end
end

-- the languages with rules for some of their scripts (sr_Latn, zh_Hant):
-- the default script and the scripts by region, from the likely subtags
local multiple = {}
for locale in pairs(locales) do
  local language, script = locale:match("^(%a+)_(%u%l%l%l)")
  if script then multiple[language] = true end
end
local scripts = {}
local likely = read(dir .. "/likelySubtags.xml")
for from, to in likely:gmatch("<likelySubtag%s+from=\"([^\"]+)\"%s+to=\"([^\"]+)\"") do
  local language, region = from:match("^(%a+)_?(%u?%u?%d?%d?%d?)$")
  if language and multiple[language] then
    local script = to:match("^%a+_(%u%l%l%l)_")
    scripts[language] = scripts[language] or {}
    if region == "" then
      scripts[language].default = script
    else
      scripts[language][region] = script
    end
  end
end
-- only the regions with another script than the default one
for _, list in pairs(scripts) do
  for region, script in pairs(list) do
    if region ~= "default" and script == list.default then list[region] = nil end
  end
end

-- the output, sorted, the rules as long strings
local function long_string(text)
  local level = ""
  while text:find("]" .. level .. "]", 1, true) do level = level .. "=" end
  if text == "" then return "\"\"" end
  -- a newline before the end: a text can end with ]
  return "[" .. level .. "[\n" .. text .. "\n]" .. level .. "]"
end

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local keywords = {}
for word in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do
  keywords[word] = true
end
local function key(name)
  if name:match("^[%a_][%w_]*$") and not keywords[name] then return name end
  return string.format("[%q]", name)
end

local out = {}
out[#out + 1] = "-- generated by tools/make_collations.lua from CLDR's common/collation,"
out[#out + 1] = "-- supplementalData.xml and likelySubtags.xml"
out[#out + 1] = "return {"
out[#out + 1] = "  -- the rules of each locale by collation type; default: the default type"
out[#out + 1] = "  locales = {"
for _, locale in ipairs(sorted_keys(locales)) do
  out[#out + 1] = "    " .. key(locale) .. " = {"
  local entry = locales[locale]
  for _, kind in ipairs(sorted_keys(entry)) do
    if kind == "default" then
      out[#out + 1] = string.format("      default = %q,", entry.default)
    else
      out[#out + 1] = "      " .. key(kind) .. " = " .. long_string(entry[kind]) .. ","
    end
  end
  out[#out + 1] = "    },"
end
out[#out + 1] = "  },"
out[#out + 1] = "  -- the parent locales that are not the locale without its last subtag"
out[#out + 1] = "  parents = {"
for _, child in ipairs(sorted_keys(parents)) do
  out[#out + 1] = string.format("    %s = %q,", key(child), parents[child])
end
out[#out + 1] = "  },"
out[#out + 1] = "  -- the scripts of the languages with rules for more than one script: the"
out[#out + 1] = "  -- default one, and those of the regions where it is another"
out[#out + 1] = "  scripts = {"
for _, language in ipairs(sorted_keys(scripts)) do
  local list = scripts[language]
  local items = {string.format("default = %q", list.default)}
  for _, region in ipairs(sorted_keys(list)) do
    if region ~= "default" then items[#items + 1] = string.format("%s = %q", key(region), list[region]) end
  end
  out[#out + 1] = "    " .. key(language) .. " = {" .. table.concat(items, ", ") .. "},"
end
out[#out + 1] = "  },"
out[#out + 1] = "}"
print(table.concat(out, "\n"))
