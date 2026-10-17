-- the root collation table; this name is kept for compatibility, the table
-- is CLDR's root collation (lua-uca-root.lua)
if kpse then
  return require "lua-uca.lua-uca-root"
end
return require "lua-uca.root"
