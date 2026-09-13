# Style and Conventions

## Lua Style
- **LuaJIT standard** (`std = "luajit"` in .luacheckrc)
- `vim` is a global (Neovim API)
- Max line length: **120 characters**
- `.deps/` directory is excluded from linting

## Naming
- Modules use snake_case filenames
- Functions and variables: snake_case
- Module tables returned at end of file (standard Lua module pattern)

## Code patterns
- Each module returns a table at the end
- State is managed in dedicated `state.lua` files per UI component
- UI components split into: orchestrator, model, view, actions, keymaps, state sub-modules
- Utility functions grouped in `util/` (buf, prompt, safe, validate)

## No formatter configured
- Only luacheck for linting; no stylua or other auto-formatter in Makefile
