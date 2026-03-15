PLENARY_DIR  := .deps/plenary.nvim
PLENARY_REPO := https://github.com/nvim-lua/plenary.nvim

.PHONY: test deps lint

deps:
	@[ -d "$(PLENARY_DIR)" ] || (mkdir -p .deps && git clone --depth=1 $(PLENARY_REPO) $(PLENARY_DIR))

test: deps
	nvim --headless --noplugin \
	  -c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua', sequential = true, timeout = 10000 }" \
	  -c "qa!"

lint:
	luacheck lua/ --globals vim
