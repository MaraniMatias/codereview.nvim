PLENARY_DIR  := .deps/plenary.nvim
PLENARY_REPO := https://github.com/nvim-lua/plenary.nvim

.PHONY: test deps lint

deps:
	@[ -d "$(PLENARY_DIR)" ] || (mkdir -p .deps && git clone --depth=1 $(PLENARY_REPO) $(PLENARY_DIR))

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests { sequential = true, timeout = 10000 }" \
	  -c "qa!"

lint:
	luacheck lua/ --globals vim
