local M = {}

local config = require("codereview.config")
local layout = require("codereview.ui.layout")
local actions = require("codereview.ui.explorer.actions")

function M.setup(buf)
  local km = config.options.keymaps
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  -- Debounced preview: avoids triggering a diff render on every keypress
  -- when the user holds j/k or uses motions like 5j, gg, G, /search, etc.
  local preview_timer = nil
  local function debounced_preview(preview_opts)
    if preview_timer then
      preview_timer:stop()
      preview_timer = nil
    end
    preview_timer = vim.defer_fn(function()
      preview_timer = nil
      actions.preview_current(preview_opts)
    end, 50)
  end

  vim.keymap.set("n", "j", function()
    vim.cmd("normal! j")
    debounced_preview({ preserve_cursor = true, move_cursor = false })
  end, opts)
  vim.keymap.set("n", "k", function()
    vim.cmd("normal! k")
    debounced_preview({ preserve_cursor = true, move_cursor = false })
  end, opts)
  vim.keymap.set("n", "<CR>", actions.open_current, opts)
  vim.keymap.set("n", "l", actions.open_current, opts)
  -- NOTE: "h" intentionally NOT bound to toggle_notes — it conflicts with
  -- standard vim left-movement muscle memory. Use km.toggle_notes (default: za).
  vim.keymap.set("n", km.toggle_notes, actions.toggle_notes, opts)
  vim.keymap.set("n", km.next_file, actions.next_file, opts)
  vim.keymap.set("n", km.prev_file, actions.prev_file, opts)
  vim.keymap.set("n", km.refresh, actions.refresh, opts)
  vim.keymap.set("n", km.quit, actions.quit, opts)
  vim.keymap.set("n", km.cycle_focus, actions.cycle_focus, opts)
  if km.toggle_layout then
    vim.keymap.set("n", km.toggle_layout, actions.toggle_layout, opts)
  end
  if km.save then
    vim.keymap.set("n", km.save, actions.save, opts)
  end
  vim.keymap.set("n", "?", actions.show_help, opts)

  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)

  -- CursorMoved covers motions not handled by j/k bindings (gg, G, /, n, etc.)
  local last_lnum = nil
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      if lnum ~= last_lnum then
        last_lnum = lnum
        debounced_preview({ preserve_cursor = true, move_cursor = false })
      end
    end,
  })

  -- CursorHold as a fallback for edge cases where CursorMoved didn't fire
  vim.api.nvim_create_autocmd("CursorHold", {
    buffer = buf,
    callback = function()
      actions.preview_current({ preserve_cursor = true })
    end,
  })
end

return M
