# Codebase Structure

```
lua/codereview/
  config.lua          -- plugin configuration/defaults
  diff_parser.lua     -- git diff parsing
  events.lua          -- event system
  git.lua             -- git integration
  init.lua            -- plugin entry point / public API
  state.lua           -- global state
  notes/
    store.lua         -- note storage
    virtual.lua       -- virtual text display
  review/
    exporter.lua      -- markdown export logic
  telescope/
    init.lua          -- telescope picker integration
  ui/
    diff_view.lua     -- diff view orchestrator
    diff_view/
      highlights.lua  -- syntax highlighting
      inline_diff.lua -- word-level inline diff
      keymaps.lua     -- diff view keybindings
      split.lua       -- split layout
      state.lua       -- diff view state
    explorer.lua      -- file explorer orchestrator
    explorer/
      actions.lua     -- explorer actions
      keymaps.lua     -- explorer keybindings
      model.lua       -- explorer data model
      state.lua       -- explorer state
      view.lua        -- explorer rendering
    layout/
      factory.lua     -- layout creation
      init.lua        -- layout orchestration
    note_float.lua    -- floating note window
  util/
    buf.lua           -- buffer utilities
    prompt.lua        -- prompt utilities
    safe.lua          -- safe call wrappers
    validate.lua      -- input validation

plugin/codereview.lua   -- Neovim plugin loader (autoloaded by Neovim)
bin/codereview          -- CLI entry point script
tests/codereview/       -- busted spec files (one per module)
tests/minimal_init.lua  -- minimal Neovim init for headless tests
.deps/plenary.nvim/     -- test dependency (gitignored)
```
