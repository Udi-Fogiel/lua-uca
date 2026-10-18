local ducet = require "lua-uca.lua-uca-ducet"
local collator = require "lua-uca.lua-uca-collator"
local collator_obj = collator.new(ducet)

describe("collator test suite",function()
  it("collator keys should be set", function()
    assert.truthy(collator_obj.codes)
    assert.truthy(collator_obj.codes[string.byte("a")])
  end)
  it("implicit weights should work", function()
    -- unassigned code points, as ICU: lead byte E4, then the code point + 1
    -- in three bytes (the last with gaps of 13)
    local weight, pos = collator:get_implicit_weight({2222}, 1)
    assert.same({{0xE4047D80, 0x0500, 0x0500}}, weight)
    assert.truthy(pos==2)
    -- Han in the order of the Unified_Ideograph ranges, three-byte primaries
    -- with step 2: core Han first, then Extension A, then the others
    assert.same({{0xE0020200, 0x0500, 0x0500}}, collator:get_implicit_weight({0x4E00}, 1))
    assert.same({{0xE0020400, 0x0500, 0x0500}}, collator:get_implicit_weight({0x4E01}, 1))
    local core = collator:get_implicit_weight({0x9FFF}, 1)[1][1]
    local extension_a = collator:get_implicit_weight({0x3400}, 1)[1][1]
    local extension_b = collator:get_implicit_weight({0x20000}, 1)[1][1]
    assert.truthy(core < extension_a and extension_a < extension_b)
    assert.truthy(extension_b < collator:get_implicit_weight({0xE0000}, 1)[1][1])
  end)
  it("implicit weights should sort Han after the explicit weights", function()
    -- U+12034 is a cuneiform sign, with explicit weights
    -- the Kangxi radical U+2F00 refers to U+4E00, with another tertiary weight
    local a = collator_obj:make_sort_key({0x12034})
    local b = collator_obj:make_sort_key({0x2F00})
    local c = collator_obj:make_sort_key({0x4E00})
    local d = collator_obj:make_sort_key({0x4E01})
    assert.truthy(collator_obj:compare(a, c))
    assert.truthy(collator_obj:compare(c, b))
    assert.truthy(collator_obj:compare(b, d))
  end)
  it("contractions should work", function()
    -- non-sense codepoint
    local codepoints = {0x1223228877119}
    local weights, pos = collator_obj:read_weight(codepoints, 1)
    assert.truthy(weights == nil)
    local codepoints = {0x0FB2, 0x0F80}
    local weights, pos = collator_obj:read_weight(codepoints, 1)
    -- it should read 
    assert.truthy(pos == 3)

  end)
  it("discontiguous contractions should work", function()
    -- alef + madda above (U+0653) is a contraction, U+0591 (class 220)
    -- between them doesn't block it
    local contraction = collator_obj:make_sort_key({0x0627, 0x0653, 0x0591})
    assert.same(contraction, collator_obj:make_sort_key({0x0627, 0x0591, 0x0653}))
    -- U+0592 has the same class as U+0653 (230) and blocks it
    local blocked = collator_obj:make_sort_key({0x0627, 0x0592, 0x0653})
    local unblocked = collator_obj:make_sort_key({0x0627, 0x0653, 0x0592})
    assert.truthy(collator_obj:compare(blocked, unblocked) or collator_obj:compare(unblocked, blocked))
  end)
  it("backward secondary weights should be reversed in segments", function()
    local backward = collator.new(ducet)
    backward.accents_backward = true
    -- the secondary level of the sort key, between the first two zeroes
    local function secondary(codepoints)
      local key = backward:make_sort_key(codepoints)
      local level, zeroes = {}, 0
      for _, weight in ipairs(key) do
        if weight == 0 then
          zeroes = zeroes + 1
          if zeroes == 2 then break end
        elseif zeroes == 1 then
          level[#level + 1] = weight
        end
      end
      return level
    end
    local function weight(codepoint) return backward:get_weights({codepoint}, 1)[1][2] end
    -- a, acute, U+FFFE, b: the segment before U+FFFE is reversed alone
    assert.same({weight(0x0301), weight(0x61), weight(0xFFFE), weight(0x62)},
      secondary({0x61, 0x0301, 0xFFFE, 0x62}))
    -- without U+FFFE the whole level is reversed
    assert.same({weight(0x62), weight(0x0301), weight(0x61)}, secondary({0x61, 0x0301, 0x62}))
  end)
  it("variable weighting should work", function()
    local function sorted(variable)
      local c = collator.new(ducet)
      c.variable_weighting = variable
      local t = {"deluge", "de-luge", "demark", "de luge", "death"}
      table.sort(t, function(a, b) return c:compare_strings(a, b) end)
      return t, c
    end
    assert.same({"de luge", "de-luge", "death", "deluge", "demark"}, sorted("non-ignorable"))
    assert.same({"de luge", "de-luge", "death", "deluge", "demark"}, sorted(nil))
    -- shifted: space and hyphen are ignored up to the quaternary level
    assert.same({"death", "de luge", "de-luge", "deluge", "demark"}, sorted("shifted"))
    -- blanked: they are ignored
    local _, blanked = sorted("blanked")
    local key = function(s) return blanked:make_sort_key(blanked:string_to_codepoints(s)) end
    assert.same(key("deluge"), key("de-luge"))
    assert.same(key("deluge"), key("de luge"))
  end)
  it("identical level should work", function()
    local c = collator.new(ducet)
    -- U+0001 is ignorable, the sort keys are equal without the identical level
    assert.same(c:make_sort_key({0x61}), c:make_sort_key({0x61, 0x01}))
    c.identical_level = true
    assert.truthy(c:compare(c:make_sort_key({0x61}), c:make_sort_key({0x61, 0x01})))
    -- U+FFFE has the minimal weight on the identical level
    assert.truthy(c:compare(c:make_sort_key({0x6C, 0xFFFE, 0x66}), c:make_sort_key({0x6C, 0x01, 0xFFFE, 0x66})))
    -- canonical equivalents are still equal
    assert.same(c:make_sort_key(c:string_to_codepoints("é")), c:make_sort_key(c:string_to_codepoints("e\u{301}")))
  end)
  it("options should work", function()
    local key = function(c, s) return c:make_sort_key(c:string_to_codepoints(s)) end
    -- options at the creation, or with set
    local c = collator.new(ducet, {variable_weighting = "blanked"})
    assert.same(key(c, "deluge"), key(c, "de-luge"))
    c:set {variable_weighting = "non-ignorable"}
    assert.falsy(c:compare_strings("deluge", "de-luge") == c:compare_strings("de-luge", "deluge"))
    -- the cache of sort keys is cleared when an option changes, also when it
    -- is assigned as a field
    local d = collator.new(ducet)
    local before = d:compare_strings("de-luge", "deluge")
    d.variable_weighting = "blanked"
    assert.falsy(d:compare_strings("de-luge", "deluge"))
    assert.falsy(d:compare_strings("deluge", "de-luge"))
    assert.truthy(before)
    -- unknown options and wrong values are errors
    assert.falsy(pcall(collator.new, ducet, {variable = "shifted"}))
    assert.falsy(pcall(collator.new, ducet, {variable_weighting = "ignore"}))
    assert.falsy(pcall(function() d.identical_level = "yes" end))
  end)
  it("max_variable should work", function()
    -- with shifted, symbols are variable with "symbol" and "ducet", not with
    -- "punct" (the default)
    local shifted = function(max) return collator.new(ducet, {variable_weighting = "shifted", max_variable = max}) end
    -- a non-variable symbol sorts before the letters, so "a♥b" < "aa"; an
    -- ignored one leaves "ab" > "aa"
    local ignored = function(c) return not c:compare_strings("a\u{2665}b", "aa") end
    assert.falsy(ignored(shifted()))
    assert.falsy(ignored(shifted("punct")))
    assert.truthy(ignored(shifted("symbol")))
    assert.truthy(ignored(shifted("ducet")))
    -- punctuation is variable with "punct", not with "space"
    assert.falsy(shifted("punct"):compare_strings("a-c", "ab"))
    assert.truthy(shifted("space"):compare_strings("a-c", "ab"))
  end)
  it("case parameters should work", function()
    local sorted = function(options)
      local c = collator.new(ducet, options)
      local t = {"a", "A", "ａ", "Ａ", "ぁ", "あ", "ァ", "ア"}
      table.sort(t, function(x, y) return c:compare_strings(x, y) end)
      return t
    end
    -- the tertiary weights: case is one of the tertiary differences
    assert.same({"a", "ａ", "A", "Ａ", "ぁ", "あ", "ァ", "ア"}, sorted {})
    -- uppercase first; large Kana are "uppercase", small ones "lowercase"
    assert.same({"A", "Ａ", "a", "ａ", "あ", "ア", "ぁ", "ァ"}, sorted {case_first = "upper"})
    assert.same({"a", "ａ", "A", "Ａ", "ぁ", "ァ", "あ", "ア"}, sorted {case_first = "lower"})
    assert.same(sorted {case_first = "lower"}, sorted {case_level = true})
    -- uppercase_first is case_first = "upper"
    local c = collator.new(ducet)
    c:uppercase_first()
    assert.same("upper", c.settings.case_first)
  end)
  it("han_order should work", function()
    local sorted = function(order)
      local c = collator.new(ducet, {han_order = order})
      -- U+2F00 (Kangxi radical one) refers to U+4E00
      local t = {"\u{4E01}", "\u{2A6D9}", "\u{4E00}", "\u{2F00}"}
      table.sort(t, function(x, y) return c:compare_strings(x, y) end)
      return t
    end
    -- the implicit order: core Han before Extension B
    assert.same({"\u{4E00}", "\u{2F00}", "\u{4E01}", "\u{2A6D9}"}, sorted())
    -- radical-stroke: U+2A6D9 has radical 1 and no residual strokes
    assert.same({"\u{4E00}", "\u{2F00}", "\u{2A6D9}", "\u{4E01}"}, sorted "radical-stroke")
    -- only when the collator is created
    local c = collator.new(ducet)
    assert.falsy(pcall(function() c:set {han_order = "radical-stroke"} end))
  end)
  it("Hangul syllables should get the weights of their jamo", function()
    local c = collator.new(ducet)
    -- also when the input is not in NFD
    assert.same(c:make_sort_key {0x1100, 0x1161, 0x11A8}, c:make_sort_key {0xAC01})
    assert.truthy(c:compare(c:make_sort_key {0xD55C}, c:make_sort_key {0x6F22}))
  end)
  it("numeric collation should work", function()
    local c = collator.new(ducet, {numeric = true})
    local t = {"a10", "a2", "a1000000000", "a01", "a١٥", "a9"}
    table.sort(t, function(a, b) return c:compare_strings(a, b) end)
    assert.same({"a01", "a2", "a9", "a10", "a١٥", "a1000000000"}, t)
    -- leading zeros are ignored, up to the identical level
    assert.same(c:make_sort_key(c:string_to_codepoints("1")), c:make_sort_key(c:string_to_codepoints("001")))
    local d = collator.new(ducet)
    d:tailor_string "[numericOrdering on]"
    assert.truthy(d:compare_strings("2", "10"))
  end)
  it("should make sort keys", function()
    local codepoints = {0x0FB2, 0x0F80, string.byte("a")}
    local sort_key = collator_obj:make_sort_key(codepoints)
    -- assert two collation elements * 3 levels + 3 separator zeroes (there is one trailing at the end of the sort key)
    assert.truthy(#sort_key, 2 * 3 + 3)
  end)
  it("should compare strings", function()
    local get_sortkey = function(a) 
      local codepoints = {}
      for _, code in utf8.codes(a) do codepoints[#codepoints+1] = code end
      return collator_obj:make_sort_key(codepoints) 
    end
    local abc = get_sortkey("abc")
    local bbc = get_sortkey("bbc")
    local abcd = get_sortkey("abcd")
    assert.truthy(collator_obj:compare(abc, bbc))
    assert.truthy(collator_obj:compare(bbc,abc)==false)
    assert.truthy(collator_obj:compare(abc, abcd))
    -- compare strings
    --
    assert.truthy(collator_obj:compare_strings("abc", "abcd"))

    -- try to sort a table
    local t = {"med", "Med", "dabing",  "měď", "da capo", "ďábel", "zeď", "medvěd","motýlek", "kánon", "motýl noční", "ucho","kaňon", "úchop", "uchopit", "kanon", "kanón", "cáp", "čáp", "cep"}
    local cache = {}
    table.sort(t, function(a,b)
      local asortkey = cache[a] or get_sortkey(a)
      local bsortkey = cache[b] or get_sortkey(b)
      cache[a], cache[b] = asortkey, bsortkey
      return collator_obj:compare(asortkey, bsortkey)
    end)
    local reverse_table = {}
    for i, x in ipairs(t) do 
      -- this will enable us to test position of words in the sorted table
      reverse_table[x] = i
      print(x) 
    end
    local function assert_smaller(a, b) assert.truthy(reverse_table[a] < reverse_table[b]) end
    assert_smaller("měď", "medvěd")
    assert_smaller("da capo", "ďábel")
    assert_smaller("ucho", "úchop")

  end)
  it("should support tailoring", function()
    local h = collator_obj:string_to_codepoints("h")
    local ch = collator_obj:string_to_codepoints("ch")
    local c = collator_obj:string_to_codepoints("c")
    local ccaron = collator_obj:string_to_codepoints("č")
    local r = collator_obj:string_to_codepoints("r")
    local rcaron = collator_obj:string_to_codepoints("ř")
    local s = collator_obj:string_to_codepoints("s")
    local scaron = collator_obj:string_to_codepoints("š")
    local z = collator_obj:string_to_codepoints("z")
    local zcaron = collator_obj:string_to_codepoints("ž")
    local tailoring_table = {1, 0, 0}
    collator_obj:tailor(h, ch, tailoring_table)
    collator_obj:tailor(c, ccaron, tailoring_table)
    collator_obj:tailor(r, rcaron, tailoring_table)
    collator_obj:tailor(s, scaron, tailoring_table)
    collator_obj:tailor(z, zcaron, tailoring_table)
    local t = {"cd", "be", "ce", "zbla", "cha", "ha","ie", "čáp", "dada", "rak", "řak", "se", "še", "te", "za", "ža"}
    table.sort(t, function(a,b)
      return collator_obj:compare_strings(a,b)
    end)
    for i, x in ipairs(t) do
      print(x)
    end

  end)

end)
