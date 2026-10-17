lua_content = $(wildcard src/lua-uca/*.lua) 
TEXMFHOME = $(shell kpsewhich -var-value=TEXMFHOME)
INSTALL_DIR = ${TEXMFHOME}/scripts/lua/lua-uca/
LUA_DIR = src/lua-uca/
VERSION:= undefined
DATE:= undefined
README = README.md
DOC_BASE = lua-uca-doc
DOC_SOURCES = $(DOC_BASE).tex $(README) CHANGELOG.md LICENSE HACKING.md
DOC_PDF = $(DOC_BASE).pdf
BUILD_DIR = build

ifeq ($(strip $(shell git rev-parse --is-inside-work-tree 2>/dev/null)),true)
	VERSION:= $(shell git --no-pager describe --abbrev=0 --tags --always )
	DATE:= $(firstword $(shell git --no-pager show --date=short --format="%ad" --name-only))
endif


all: data/common src/lua-uca/lua-uca-root.lua src/lua-uca/lua-uca-root-info.lua src/lua-uca/lua-uca-root-jit.lua src/lua-uca/lua-uca-reordering-table.lua src/lua-uca/lua-uca-ccc.lua src/lua-uca/lua-uca-chinese.lua $(DOC_PDF)

UCA_URL = https://www.unicode.org/Public/UCA/latest
UCD_URL = https://www.unicode.org/Public/UCD/latest/ucd
# the root collation and its conformance tests, from CLDR's development version
CLDR_URL = https://raw.githubusercontent.com/unicode-org/cldr/main/common/uca
WGET = wget --no-use-server-timestamps

data/allkeys.txt:
	mkdir -p data
	$(WGET) -O $@.tmp $(UCA_URL)/allkeys.txt && mv $@.tmp $@

data/UnicodeData.txt data/Scripts.txt data/PropertyValueAliases.txt:
	mkdir -p data
	$(WGET) -O $@.tmp $(UCD_URL)/$(notdir $@) && mv $@.tmp $@

data/FractionalUCA.txt:
	mkdir -p data
	$(WGET) -O $@.tmp $(CLDR_URL)/FractionalUCA.txt && mv $@.tmp $@

# the conformance tests of the UCA and of CLDR's root collation
CLDR_TESTS = NON_IGNORABLE NON_IGNORABLE_SHORT SHIFTED SHIFTED_SHORT
data/CollationTest:
	mkdir -p data
	$(WGET) -O data/CollationTest.zip $(UCA_URL)/CollationTest.zip
	rm -rf $@
	unzip -q data/CollationTest.zip -d data/
	rm data/CollationTest.zip
	for test in $(CLDR_TESTS); do \
	  $(WGET) -O $@/CollationTest_CLDR_$$test.txt $(CLDR_URL)/CollationTest_CLDR_$$test.txt || exit 1; \
	done

# download all the Unicode data again, for a new Unicode version
fetch:
	rm -f data/allkeys.txt data/FractionalUCA.txt data/UnicodeData.txt data/Scripts.txt data/PropertyValueAliases.txt
	rm -rf data/CollationTest
	$(MAKE) data/allkeys.txt data/FractionalUCA.txt data/UnicodeData.txt data/Scripts.txt data/PropertyValueAliases.txt data/CollationTest

data/common:
	wget http://unicode.org/Public/cldr/33/cldr-common-33.0.zip
	unzip cldr-common-33.0.zip "common/collation/*" -d data/
	rm cldr-common-33.0.zip

src/lua-uca/lua-uca-root.lua: data/FractionalUCA.txt
	mkdir -p src/lua-uca
	texlua tools/make_root.lua table > $@

src/lua-uca/lua-uca-root-info.lua: data/FractionalUCA.txt
	mkdir -p src/lua-uca
	texlua tools/make_root.lua info > $@

src/lua-uca/lua-uca-root-jit.lua: src/lua-uca/lua-uca-root.lua
	texlua tools/make_root_jit.lua > $@

src/lua-uca/lua-uca-reordering-table.lua: data/FractionalUCA.txt data/Scripts.txt data/PropertyValueAliases.txt data/UnicodeData.txt
	mkdir -p src/lua-uca
	texlua tools/make_reordering_table.lua > $@

src/lua-uca/lua-uca-ccc.lua: data/UnicodeData.txt
	mkdir -p src/lua-uca
	texlua tools/make_ccc.lua > $@

.PHONY: test install conformance fetch

conformance:
	@test -d data/CollationTest || { echo "The conformance tests are missing, run make fetch"; exit 1; }
	texlua tools/conformance.lua

test:
	luarocks make --local
	busted spec/ducet-spec.lua
	busted spec/collator_spec.lua
	busted spec/languages-spec.lua
	busted spec/tailoring-spec.lua

$(DOC_PDF): $(DOC_SOURCES) 
	lualatex '\def\version{${VERSION}}\def\gitdate{${DATE}}\input{$<}'


install: 
	mkdir -p ${INSTALL_DIR}
	cp ${LUA_DIR}*.lua ${INSTALL_DIR}

xindex: 
	$(MAKE) -C $@

build: $(DOC_PDF) $(DOC_SOURCES) $(lua_content) 
	mkdir -p $(BUILD_DIR)/lua-uca/lua-uca
	cp $(lua_content) $(BUILD_DIR)/lua-uca/lua-uca/
	cp $(DOC_PDF) $(DOC_SOURCES) Makefile $(BUILD_DIR)/lua-uca/
	@cd $(BUILD_DIR) && zip -r lua-uca.zip lua-uca


.PHONY: all xindex build
