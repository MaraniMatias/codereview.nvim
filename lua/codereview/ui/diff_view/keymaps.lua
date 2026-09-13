local M = {}

local config = require("codereview.config")
local state = require("codereview.state")
local diff_state = require("codereview.ui.diff_view.state")
local virtual = require("codereview.notes.virtual")

function M.setup(buf, diff_view)
  local cfg = config.options
  local km = cfg.keymaps
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }
  local function map(mode, lhs, callback)
    if lhs then vim.keymap.set(mode, lhs, callback, opts) end
  end

  local add_note = function()
    local info = diff_view.get_current_line_info()
    if not info then return end
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    local existing = require("codereview.notes.store").get(file.path, info.lnum, info.side)
    local code = diff_view.get_code_context_for_side(info.lnum, info.lnum, info.side)
    require("codereview.ui.note_float").open(file.path, info.lnum, info.lnum, code, existing and existing.text, info.side)
  end
  map("n", km.note, add_note)

  local add_visual_note = function()
    local vstart = vim.fn.line("v")
    local vend = vim.fn.line(".")
    if vstart > vend then vstart, vend = vend, vstart end

    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end

    local side, lnum_start, lnum_end

    if config.is_split_mode() then
      local current_win = vim.api.nvim_get_current_win()
      if current_win == s.windows.diff_old then
        side = "old"
        local display_old = diff_state.get_old()
        lnum_start = display_old.line_map[vstart]
        lnum_end = display_old.line_map[vend]
      else
        side = "new"
        local display = diff_state.get()
        lnum_start = display.line_map[vstart]
        lnum_end = display.line_map[vend]
      end
    else
      local display = diff_state.get()
      local first_type = display.line_type_map[vstart]
      side = (first_type == "del") and "old" or "new"

      -- detect mixed selection (crossing add + del lines) and warn
      local has_mixed = false
      for dl = vstart, vend do
        local lt = display.line_type_map[dl]
        if lt then
          local line_side = (lt == "del") and "old" or "new"
          if line_side ~= side then
            has_mixed = true
            break
          end
        end
      end
      if has_mixed then
        vim.api.nvim_echo(
          { { "CodeReview: selection crosses add/del boundary — using '" .. side .. "' side only", "WarningMsg" } },
          false, {}
        )
      end

      if side == "old" then
        lnum_start = display.old_line_map[vstart]
        lnum_end = display.old_line_map[vend]
      else
        lnum_start = display.line_map[vstart]
        lnum_end = display.line_map[vend]
      end
    end

    if not lnum_start then return end
    lnum_end = lnum_end or lnum_start

    local code = diff_view.get_code_context_for_side(lnum_start, lnum_end, side)
    require("codereview.ui.note_float").open(file.path, lnum_start, lnum_end, code, nil, side)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end
  map("v", km.note, add_visual_note)

  map("n", km.next_note, function()
    diff_view._jump_note(1)
  end)
  map("n", km.prev_note, function()
    diff_view._jump_note(-1)
  end)

  local layout = require("codereview.ui.layout")
  local explorer = require("codereview.ui.explorer")
  map("n", km.next_file, function()
    local s = state.get()
    if s.current_file_idx < #s.files then
      explorer.preview_action({ type = "file", idx = s.current_file_idx + 1 }, { move_cursor = true })
    end
  end)
  map("n", km.prev_file, function()
    local s = state.get()
    if s.current_file_idx > 1 then
      explorer.preview_action({ type = "file", idx = s.current_file_idx - 1 }, { move_cursor = true })
    end
  end)

  if km.save then
    map("n", km.save, function()
      require("codereview.review.exporter").save_with_prompt()
    end)
  end

  map("n", km.notes_picker, function()
    require("codereview.telescope").open_notes_picker()
  end)

  map("n", km.toggle_virtual_text, function()
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    if config.is_split_mode() then
      virtual.toggle_split(s.buffers.diff_old, s.buffers.diff_new, file.path, diff_state.get_old(), diff_state.get())
    else
      virtual.toggle(s.buffers.diff, file.path, diff_state.get())
    end
  end)

  map("n", km.load_more_diff, function()
    diff_view.load_more()
  end)

  map("n", km.go_to_file, function()
    diff_view._open_file_in_tab(true)
  end)

  map("n", km.view_file, function()
    diff_view._open_file_in_tab(false)
  end)

  map("n", km.toggle_hunk_fold, function()
    diff_view._toggle_hunk_fold()
  end)

  map("n", km.cycle_focus, function()
    if config.is_split_mode() and layout.is_diff_old_focused() then
      layout.focus_diff_new()
    else
      layout.focus_explorer()
    end
  end)

  map("n", km.quit, function()
    local note_float = require("codereview.ui.note_float")
    if note_float.is_open() then
      note_float.ask_save_or_discard()
      return
    end
    layout.quit_with_prompt()
  end)

  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)
end

return M
