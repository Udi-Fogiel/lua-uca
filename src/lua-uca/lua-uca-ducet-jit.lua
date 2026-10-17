-- the root collation table for LuaJIT; this name is kept for compatibility,
-- the table is CLDR's root collation (lua-uca-root-jit.lua)
if kpse then
  return require "lua-uca.lua-uca-root-jit"
end
return require "lua-uca.root-jit"
