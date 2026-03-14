local M = {}
local state = require("cowork2md.state")
local config = require("cowork2md.config")
local diff_parser = require("cowork2md.diff_parser")
local virtual = require("cowork2md.notes.virtual")
local git = require("cowork2md.git")

-- Current file's display data
local current_display = {
  lines = {},
  line_types = {},
  line_map = {},  -- display_line (1-based) -> new_lnum (1-based)
}

-- Show diff for a file by index
function M.show_file(idx)
  local s = state.get()
  local buf = s.buffers.diff
  local file = s.files[idx]
  if not file or not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  s.current_file_idx = idx

  -- Get the diff text
  local diff_text = M._get_diff_for_file(file)
  if not diff_text or diff_text == "" then
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "  (no changes)" })
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    return
  end

  -- Parse diff
  local parsed = diff_parser.parse(diff_text)
  local lines, line_types = diff_parser.get_display_lines(parsed)

  -- Build line_map: display line -> new_lnum
  local line_map = {}
  local display_lnum = 1
  for _, hunk in ipairs(parsed.hunks) do
    display_lnum = display_lnum + 1  -- header line
    for _, l in ipairs(hunk.lines) do
      if l.new_lnum then
        line_map[display_lnum] = l.new_lnum
      end
      display_lnum = display_lnum + 1
    end
  end

  current_display.lines = lines
  current_display.line_types = line_types
  current_display.line_map = line_map

  -- Write to buffer
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Apply diff highlights
  M._apply_diff_highlights(buf, line_types)

  -- Apply syntax highlight for the file type
  local ext = file.path:match("%.([^%.]+)$")
  if ext then
    local ok, lang = pcall(vim.treesitter.language.get_lang, ext)
    if ok and lang then
      pcall(vim.treesitter.start, buf, lang)
    end
  end

  -- Render notes as virtual text
  virtual.render_notes(buf, file.path, line_map)

  -- Set buffer name to show current file
  pcall(vim.api.nvim_buf_set_name, buf, "cowork2md://" .. file.path)

  -- Move cursor to top
  if s.windows.diff and vim.api.nvim_win_is_valid(s.windows.diff) then
    vim.api.nvim_win_set_cursor(s.windows.diff, { 1, 0 })
  end
end

function M._get_diff_for_file(file)
  local s = state.get()
  if s.mode == "difftool" then
    return git.get_difftool_diff(file)
  else
    return git.get_file_diff(s.root, file.path, s.diff_ref)
  end
end

function M._apply_diff_highlights(buf, line_types)
  local ns = vim.api.nvim_create_namespace("cowork2md_diff")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for lnum, ltype in ipairs(line_types) do
    local hl
    if ltype == "add" then
      hl = "DiffAdd"
    elseif ltype == "del" then
      hl = "DiffDelete"
    elseif ltype == "hdr" then
      hl = "DiffChange"
    end
    if hl then
      vim.api.nvim_buf_add_highlight(buf, ns, hl, lnum - 1, 0, -1)
    end
  end
end

-- Jump to the display line nearest to new_lnum
function M.jump_to_line(new_lnum)
  local s = state.get()
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then return end

  -- Find the display line for this lnum
  local best_line = 1
  local best_dist = math.huge
  for display_l, n_lnum in pairs(current_display.line_map) do
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
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(s.windows.diff)
  local display_lnum = cursor[1]
  return current_display.line_map[display_lnum]
end

-- Get code context for lines start..end (visual selection or single line)
function M.get_code_context(line_start, line_end)
  local result = {}
  line_end = line_end or line_start

  -- Collect lines from the display that map to the requested range
  for display_l, n_lnum in pairs(current_display.line_map) do
    if n_lnum >= line_start and n_lnum <= line_end then
      result[display_l] = current_display.lines[display_l]
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

  -- Add note on current line
  vim.keymap.set("n", km.add_note, function()
    local new_lnum = M.get_current_lnum()
    if not new_lnum then return end
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    local code = M.get_code_context(new_lnum, new_lnum)
    require("cowork2md.ui.note_float").open(file.path, new_lnum, new_lnum, code)
  end, opts)

  -- Edit note on current line
  vim.keymap.set("n", km.edit_note, function()
    local new_lnum = M.get_current_lnum()
    if not new_lnum then return end
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    local existing = require("cowork2md.notes.store").get(file.path, new_lnum)
    local code = M.get_code_context(new_lnum, new_lnum)
    require("cowork2md.ui.note_float").open(file.path, new_lnum, new_lnum, code, existing and existing.text)
  end, opts)

  -- Add note from visual selection
  vim.keymap.set("v", km.add_note, function()
    -- Get visual selection range
    local vstart = vim.fn.line("v")
    local vend = vim.fn.line(".")
    if vstart > vend then vstart, vend = vend, vstart end

    -- Map visual display lines to new_lnums
    local lnum_start = current_display.line_map[vstart]
    local lnum_end = current_display.line_map[vend]
    if not lnum_start then return end
    lnum_end = lnum_end or lnum_start

    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end

    local code = M.get_code_context(lnum_start, lnum_end)
    require("cowork2md.ui.note_float").open(file.path, lnum_start, lnum_end, code)
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
  local layout = require("cowork2md.ui.layout")
  local explorer = require("cowork2md.ui.explorer")
  vim.keymap.set("n", km.next_file, function()
    local s = state.get()
    if s.current_file_idx < #s.files then
      explorer.select_file(s.current_file_idx + 1)
      M.show_file(s.current_file_idx)
    end
  end, opts)
  vim.keymap.set("n", km.prev_file, function()
    local s = state.get()
    if s.current_file_idx > 1 then
      explorer.select_file(s.current_file_idx - 1)
      M.show_file(s.current_file_idx)
    end
  end, opts)

  -- Save
  vim.keymap.set("n", km.save, function()
    require("cowork2md.review.exporter").save_with_prompt()
  end, opts)

  -- Notes picker
  vim.keymap.set("n", km.notes_picker, function()
    require("cowork2md.telescope").open_notes_picker()
  end, opts)

  -- Quit
  vim.keymap.set("n", km.quit, function()
    layout.close()
  end, opts)
end

function M._jump_note(direction)
  local s = state.get()
  local file = s.files[s.current_file_idx]
  if not file then return end

  local notes = require("cowork2md.notes.store").get_for_file(file.path)
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

-- Refresh notes display
function M.refresh_notes()
  local s = state.get()
  local buf = s.buffers.diff
  local file = s.files[s.current_file_idx]
  if not file or not buf then return end
  virtual.render_notes(buf, file.path, current_display.line_map)
end

return M
