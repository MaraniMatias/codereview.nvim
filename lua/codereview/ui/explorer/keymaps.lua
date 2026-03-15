local M = {}

local config = require("codereview.config")
local layout = require("codereview.ui.layout")
local actions = require("codereview.ui.explorer.actions")

function M.setup(buf)
  local km = config.options.keymaps
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  vim.keymap.set("n", "<CR>", actions.open_current, opts)
  vim.keymap.set("n", "l", actions.open_current, opts)
  vim.keymap.set("n", "h", actions.toggle_notes, opts)
  vim.keymap.set("n", km.toggle_notes, actions.toggle_notes, opts)
  vim.keymap.set("n", km.next_file, actions.next_file, opts)
  vim.keymap.set("n", km.prev_file, actions.prev_file, opts)
  vim.keymap.set("n", km.refresh, actions.refresh, opts)
  vim.keymap.set("n", km.quit, actions.quit, opts)
  vim.keymap.set("n", km.cycle_focus, actions.cycle_focus, opts)
  if km.save then
    vim.keymap.set("n", km.save, actions.save, opts)
  end

  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)
  vim.api.nvim_create_autocmd("CursorHold", {
    buffer = buf,
    callback = function()
      actions.preview_current({ preserve_cursor = true })
    end,
  })
end

return M
