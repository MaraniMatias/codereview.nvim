PLENARY_DIR  := .deps/plenary.nvim
PLENARY_REPO := https://github.com/nvim-lua/plenary.nvim
PLENARY_COMMIT := b9fd5226c2f76c951fc8ed5923d85e4de065e509

.PHONY: test deps lint

deps:
	@[ -d "$(PLENARY_DIR)/.git" ] || (rm -rf "$(PLENARY_DIR)" && mkdir -p .deps && git clone --filter=blob:none --no-checkout $(PLENARY_REPO) $(PLENARY_DIR))
	@git -C "$(PLENARY_DIR)" fetch --depth=1 origin $(PLENARY_COMMIT)
	@git -C "$(PLENARY_DIR)" checkout --detach $(PLENARY_COMMIT)

test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests { sequential = true, timeout = 10000 }" \
	  -c "qa!"

lint:
	luacheck lua/ --globals vim
