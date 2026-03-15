local M = {}
local state = require("codereview.state")
local config = require("codereview.config")
local diff_parser = require("codereview.diff_parser")
local virtual = require("codereview.notes.virtual")
local git = require("codereview.git")
local diff_state = require("codereview.ui.diff_view.state")
local diff_ns = vim.api.nvim_create_namespace("codereview_diff")
local diff_request_id = 0

local function reset_display()
  diff_state.reset()
end

local function set_buffer_lines(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function focus_top(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
end

-- Show diff for a file by index
function M.show_file(idx)
  local s = state.get()
  local buf = s.buffers.diff
  local file = s.files[idx]
  if not file or not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  s.current_file_idx = idx
  diff_request_id = diff_request_id + 1
  local request_id = diff_request_id

  reset_display()
  virtual.clear_extmarks(buf)
  set_buffer_lines(buf, { "  (loading diff...)" })
  pcall(vim.api.nvim_buf_set_name, buf, "codereview://" .. file.path)
  focus_top(s.windows.diff)

  M._get_diff_for_file(file, function(diff_text)
    local current_state = state.get()
    local current_file = current_state.files[current_state.current_file_idx]
    if request_id ~= diff_request_id then return end
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    if not current_file or current_file.path ~= file.path then return end

    if diff_text == nil then
      reset_display()
      set_buffer_lines(buf, { "  (failed to load diff)" })
      focus_top(current_state.windows.diff)
      return
    end

    if diff_text == "" then
      reset_display()
      set_buffer_lines(buf, { "  (no changes)" })
      focus_top(current_state.windows.diff)
      return
    end

    local parsed = diff_parser.parse(diff_text)
    local lines, line_types = diff_parser.get_display_lines(parsed)

    local header_offset = (parsed.old_file and parsed.new_file) and 2 or 0
    local line_map = {}
    local display_lnum = 1 + header_offset
    for _, hunk in ipairs(parsed.hunks) do
      display_lnum = display_lnum + 1
      for _, l in ipairs(hunk.lines) do
        if l.new_lnum then
          line_map[display_lnum] = l.new_lnum
        end
        display_lnum = display_lnum + 1
      end
    end

    diff_state.set({
      lines = lines,
      line_types = line_types,
      line_map = line_map,
    })

    set_buffer_lines(buf, lines)
    M._apply_diff_highlights(buf, line_types)

    local ext = file.path:match("%.([^%.]+)$")
    if ext then
      local ok, lang = pcall(vim.treesitter.language.get_lang, ext)
      if ok and lang then
        pcall(vim.treesitter.start, buf, lang)
      end
    end

    if current_state.notes_visible then
      virtual.render_notes(buf, file.path, line_map)
    else
      virtual.clear_extmarks(buf)
    end

    pcall(vim.api.nvim_buf_set_name, buf, "codereview://" .. file.path)
    focus_top(current_state.windows.diff)
  end)
end

function M._get_diff_for_file(file, callback)
  local s = state.get()
  if s.mode == "difftool" then
    git.get_difftool_diff(file, callback)
  else
    git.get_file_diff(s.root, file.path, s.diff_args, callback)
  end
end

function M._apply_diff_highlights(buf, line_types)
  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  -- Ensure CodeReviewFileHdr highlight group exists (linked to Label as fallback)
  vim.api.nvim_set_hl(0, "CodeReviewFileHdr", { link = "Label", default = true })

  for lnum, ltype in ipairs(line_types) do
    local hl
    if ltype == "add" then
      hl = "DiffAdd"
    elseif ltype == "del" then
      hl = "DiffDelete"
    elseif ltype == "hdr" then
      hl = "DiffChange"
    elseif ltype == "file_hdr" then
      hl = "CodeReviewFileHdr"
    end
    if hl then
      vim.api.nvim_buf_add_highlight(buf, diff_ns, hl, lnum - 1, 0, -1)
    end
  end
end

-- Jump to the display line nearest to new_lnum
function M.jump_to_line(new_lnum)
  local s = state.get()
  local display = diff_state.get()
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then return end

  -- Find the display line for this lnum
  local best_line = 1
  local best_dist = math.huge
  for display_l, n_lnum in pairs(display.line_map) do
    local dist = math.abs(n_lnum - new_lnum)
    if dist < best_dist then
      best_dist = dist
      best_line = display_l
    end
  end
  vim.api.nvim_win_set_cursor(s.windows.diff, { best_line, 0 })
end

-- Get the new_lnum for the current cursor position in diff view
function M.get_current_lnum()
  local s = state.get()
  local display = diff_state.get()
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(s.windows.diff)
  local display_lnum = cursor[1]
  return display.line_map[display_lnum]
end

-- Get code context for lines start..end (visual selection or single line)
function M.get_code_context(line_start, line_end)
  local display = diff_state.get()
  local result = {}
  line_end = line_end or line_start

  -- Collect lines from the display that map to the requested range
  for display_l, n_lnum in pairs(display.line_map) do
    if n_lnum >= line_start and n_lnum <= line_end then
      result[display_l] = display.lines[display_l]
    end
  end

  -- Build ordered list
  local keys = {}
  for k in pairs(result) do table.insert(keys, k) end
  table.sort(keys)

  local code_lines = {}
  for _, k in ipairs(keys) do
    -- Strip leading +/- from diff lines
    local line = result[k]
    if line:sub(1, 1) == "+" or line:sub(1, 1) == "-" or line:sub(1, 1) == " " then
      line = line:sub(2)
    end
    table.insert(code_lines, line)
  end

  return table.concat(code_lines, "\n")
end

-- Setup keymaps for the diff buffer
function M.setup_keymaps(buf)
  local cfg = config.options
  local km = cfg.keymaps
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  -- Add or edit note on current line (smart: pre-loads text if note exists)
  vim.keymap.set("n", km.note, function()
    local new_lnum = M.get_current_lnum()
    if not new_lnum then return end
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    local existing = require("codereview.notes.store").get(file.path, new_lnum)
    local code = M.get_code_context(new_lnum, new_lnum)
    require("codereview.ui.note_float").open(file.path, new_lnum, new_lnum, code, existing and existing.text)
  end, opts)

  -- Add note from visual selection
  vim.keymap.set("v", km.note, function()
    local display = diff_state.get()
    -- Get visual selection range
    local vstart = vim.fn.line("v")
    local vend = vim.fn.line(".")
    if vstart > vend then vstart, vend = vend, vstart end

    -- Map visual display lines to new_lnums
    local lnum_start = display.line_map[vstart]
    local lnum_end = display.line_map[vend]
    if not lnum_start then return end
    lnum_end = lnum_end or lnum_start

    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end

    local code = M.get_code_context(lnum_start, lnum_end)
    require("codereview.ui.note_float").open(file.path, lnum_start, lnum_end, code)
    -- Exit visual mode
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end, opts)

  -- Next/prev note
  vim.keymap.set("n", km.next_note, function()
    M._jump_note(1)
  end, opts)
  vim.keymap.set("n", km.prev_note, function()
    M._jump_note(-1)
  end, opts)

  -- Next/prev file
  local layout = require("codereview.ui.layout")
  local explorer = require("codereview.ui.explorer")
  vim.keymap.set("n", km.next_file, function()
    local s = state.get()
    if s.current_file_idx < #s.files then
      explorer.preview_action({ type = "file", idx = s.current_file_idx + 1 }, { move_cursor = true })
    end
  end, opts)
  vim.keymap.set("n", km.prev_file, function()
    local s = state.get()
    if s.current_file_idx > 1 then
      explorer.preview_action({ type = "file", idx = s.current_file_idx - 1 }, { move_cursor = true })
    end
  end, opts)

  -- Save
  vim.keymap.set("n", km.save, function()
    require("codereview.review.exporter").save_with_prompt()
  end, opts)

  -- Notes picker
  vim.keymap.set("n", km.notes_picker, function()
    require("codereview.telescope").open_notes_picker()
  end, opts)

  -- Toggle virtual text visibility
  vim.keymap.set("n", km.toggle_virtual_text, function()
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    virtual.toggle(s.buffers.diff, file.path, diff_state.get().line_map)
  end, opts)

  -- Cycle focus to explorer panel
  vim.keymap.set("n", km.cycle_focus, function()
    layout.focus_explorer()
  end, opts)

  -- Quit
  vim.keymap.set("n", km.quit, function()
    layout.safe_close(false)
  end, opts)

  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)
end

function M._jump_note(direction)
  local s = state.get()
  local file = s.files[s.current_file_idx]
  if not file then return end

  local notes = require("codereview.notes.store").get_for_file(file.path)
  if #notes == 0 then return end

  local current_lnum = M.get_current_lnum() or 0
  local target_note = nil

  if direction > 0 then
    for _, note in ipairs(notes) do
      if note.line_start > current_lnum then
        target_note = note
        break
      end
    end
    if not target_note then target_note = notes[1] end
  else
    for i = #notes, 1, -1 do
      if notes[i].line_start < current_lnum then
        target_note = notes[i]
        break
      end
    end
    if not target_note then target_note = notes[#notes] end
  end

  if target_note then
    M.jump_to_line(target_note.line_start)
  end
end

-- Reset diff display state (call when closing the layout)
function M.clear()
  diff_request_id = diff_request_id + 1
  reset_display()
end

-- Refresh notes display
function M.refresh_notes()
  local s = state.get()
  local buf = s.buffers.diff
  local file = s.files[s.current_file_idx]
  if not file or not buf then return end
  if s.notes_visible then
    virtual.render_notes(buf, file.path, diff_state.get().line_map)
  else
    virtual.clear_extmarks(buf)
  end
end

return M
