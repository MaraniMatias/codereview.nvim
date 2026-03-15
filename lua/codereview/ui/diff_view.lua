local M = {}
local state = require("codereview.state")
local config = require("codereview.config")
local diff_parser = require("codereview.diff_parser")
local virtual = require("codereview.notes.virtual")
local git = require("codereview.git")
local diff_state = require("codereview.ui.diff_view.state")
local diff_ns = vim.api.nvim_create_namespace("codereview_diff")
local diff_request_id = 0
local treesitter_max_lines = 5000
local _ts_lang_cache = {}   -- buf -> lang string | false
local _hl_cache = {}        -- buf -> concat key string

local function get_line_type(l)
  return l:sub(1, 1)
end

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

local function set_window_cursor(win, buf, row, col)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local line_count = math.max(1, vim.api.nvim_buf_line_count(buf))
  local clamped_row = math.min(math.max(row or 1, 1), line_count)
  local line = vim.api.nvim_buf_get_lines(buf, clamped_row - 1, clamped_row, false)[1] or ""
  local max_col = #line
  local clamped_col = math.min(math.max(col or 0, 0), max_col)

  vim.api.nvim_win_set_cursor(win, { clamped_row, clamped_col })
end

local function get_diff_limits()
  local cfg = config.options or {}
  local max_diff_lines = tonumber(cfg.max_diff_lines) or 1200
  local diff_page_size = tonumber(cfg.diff_page_size) or 400

  max_diff_lines = math.max(1, math.floor(max_diff_lines))
  diff_page_size = math.max(1, math.floor(diff_page_size))

  return {
    max_diff_lines = max_diff_lines,
    diff_page_size = diff_page_size,
  }
end

local function get_load_more_key()
  local km = (config.options or {}).keymaps or {}
  return km.load_more_diff or "L"
end

local function get_truncation_line()
  return "(diff truncado, presiona " .. get_load_more_key() .. " para cargar mas)"
end

local function build_full_display(parsed)
  local all_lines, all_line_types = diff_parser.get_display_lines(parsed)

  local header_offset = 0
  if parsed.old_file and parsed.new_file then
    header_offset = header_offset + 2
  end
  header_offset = header_offset + #(parsed.info_lines or {})

  local all_line_map = {}
  local all_new_to_display = {}
  local display_lnum = 1 + header_offset

  for _, hunk in ipairs(parsed.hunks) do
    display_lnum = display_lnum + 1
    for _, l in ipairs(hunk.lines) do
      if l.new_lnum then
        all_line_map[display_lnum] = l.new_lnum
        all_new_to_display[l.new_lnum] = display_lnum
      end
      display_lnum = display_lnum + 1
    end
  end

  return {
    all_lines = all_lines,
    all_line_types = all_line_types,
    all_line_map = all_line_map,
    all_new_to_display = all_new_to_display,
  }
end

local function get_initial_visible_until(all_line_types, max_diff_lines)
  local total_lines = #all_line_types
  if total_lines <= max_diff_lines then
    return total_lines
  end

  local visible_until = max_diff_lines
  while visible_until > 1 and all_line_types[visible_until] == "hdr" do
    visible_until = visible_until - 1
  end

  return math.max(1, visible_until)
end

local function find_best_display_line(new_to_display, new_lnum)
  local best_line = nil
  local best_dist = math.huge

  for mapped_lnum, display_lnum in pairs(new_to_display or {}) do
    local dist = math.abs(mapped_lnum - new_lnum)
    if dist < best_dist or (dist == best_dist and (best_line == nil or display_lnum < best_line)) then
      best_dist = dist
      best_line = display_lnum
    end
  end

  return best_line
end

local function render_current_display(buf, file, opts)
  opts = opts or {}

  local s = state.get()
  local display = diff_state.get()
  local win = s.windows.diff
  local cursor = nil

  if opts.preserve_cursor and win and vim.api.nvim_win_is_valid(win) then
    cursor = vim.api.nvim_win_get_cursor(win)
  end

  set_buffer_lines(buf, display.lines)
  M._apply_diff_highlights(buf, display.line_types)
  M._update_treesitter(buf, file and file.path, display.visible_until)

  if s.notes_visible and file then
    virtual.render_notes(buf, file.path, display)
  else
    virtual.clear_extmarks(buf)
  end

  if file then
    pcall(vim.api.nvim_buf_set_name, buf, "codereview://" .. file.path)
  end

  if opts.cursor_lnum and win and vim.api.nvim_win_is_valid(win) then
    set_window_cursor(win, buf, opts.cursor_lnum, 0)
    return
  end

  if cursor and win and vim.api.nvim_win_is_valid(win) then
    set_window_cursor(win, buf, cursor[1], cursor[2])
    return
  end

  if opts.focus_top then
    focus_top(win)
  end
end

local function set_visible_until(visible_until, opts)
  local s = state.get()
  local buf = s.buffers.diff
  local file = s.files[s.current_file_idx]
  local display = diff_state.get()

  if not buf or not vim.api.nvim_buf_is_valid(buf) or not file then
    return false
  end

  local clamped_visible_until = math.max(0, math.min(visible_until, #display.all_lines))
  if clamped_visible_until == display.visible_until then
    return false
  end

  diff_state.set_visible_until(clamped_visible_until)
  render_current_display(buf, file, opts)
  return true
end

local function ensure_display_line_visible(display_lnum, opts)
  local display = diff_state.get()
  if display_lnum <= display.visible_until then
    return false
  end

  local limits = get_diff_limits()
  local visible_until = display.visible_until
  while visible_until < display_lnum and visible_until < #display.all_lines do
    visible_until = math.min(#display.all_lines, visible_until + limits.diff_page_size)
  end

  return set_visible_until(visible_until, opts)
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
  _hl_cache[buf] = nil   -- force re-apply when file arrives
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
    local full_display = build_full_display(parsed)
    local limits = get_diff_limits()

    diff_state.set({
      all_lines = full_display.all_lines,
      all_line_types = full_display.all_line_types,
      all_line_map = full_display.all_line_map,
      all_new_to_display = full_display.all_new_to_display,
      visible_until = get_initial_visible_until(full_display.all_line_types, limits.max_diff_lines),
      truncation_line = get_truncation_line(),
    })

    render_current_display(buf, file)

    local pending_jump_lnum = diff_state.get().pending_jump_lnum
    if pending_jump_lnum then
      M.jump_to_line(pending_jump_lnum)
    else
      focus_top(current_state.windows.diff)
    end
  end)
end

function M._get_diff_for_file(file, callback)
  local s = state.get()
  if s.mode == "difftool" then
    if file.local_file and file.remote_file then
      git.get_difftool_diff(file, callback)
    else
      git.get_file_diff(s.root, file, {}, callback)  -- working tree diff for non-diffed files
    end
  else
    git.get_file_diff(s.root, file, s.diff_args, callback)
  end
end

function M._update_treesitter(buf, filepath, visible_until)
  local desired_lang = nil
  if filepath and visible_until > 0 and visible_until <= treesitter_max_lines then
    local ext = filepath:match("%.([^%.]+)$")
    if ext then
      local ok, lang = pcall(vim.treesitter.language.get_lang, ext)
      if ok and lang then desired_lang = lang end
    end
  end

  local cached = _ts_lang_cache[buf]

  if desired_lang == nil then
    if cached ~= false and cached ~= nil then
      pcall(vim.treesitter.stop, buf)
      _ts_lang_cache[buf] = false
    end
    return
  end

  if cached ~= desired_lang then
    if cached ~= false and cached ~= nil then
      pcall(vim.treesitter.stop, buf)
    end
    pcall(vim.treesitter.start, buf, desired_lang)
    _ts_lang_cache[buf] = desired_lang
  end
end

function M._apply_diff_highlights(buf, line_types)
  local new_key = table.concat(line_types, "\0")
  if _hl_cache[buf] == new_key then return end

  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  vim.api.nvim_set_hl(0, "CodeReviewFileHdr", { link = "Label", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewInfo", { link = "Comment", default = true })

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
    elseif ltype == "info" or ltype == "truncated" then
      hl = "CodeReviewInfo"
    end
    if hl then
      vim.api.nvim_buf_add_highlight(buf, diff_ns, hl, lnum - 1, 0, -1)
    end
  end

  _hl_cache[buf] = new_key
end

function M.load_more()
  local display = diff_state.get()
  if not display.is_truncated then
    return
  end

  local limits = get_diff_limits()
  set_visible_until(display.visible_until + limits.diff_page_size, { preserve_cursor = true })
end

-- Jump to the display line nearest to new_lnum
function M.jump_to_line(new_lnum)
  local s = state.get()
  local display = diff_state.get()

  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then
    diff_state.set_pending_jump(new_lnum)
    return
  end

  if #display.all_lines == 0 then
    diff_state.set_pending_jump(new_lnum)
    return
  end

  local target_display = display.all_new_to_display[new_lnum] or find_best_display_line(display.all_new_to_display, new_lnum)
  if not target_display then
    diff_state.set_pending_jump(nil)
    return
  end

  ensure_display_line_visible(target_display, { preserve_cursor = true })

  display = diff_state.get()
  local best_line = display.new_to_display[new_lnum] or find_best_display_line(display.new_to_display, new_lnum)
  if not best_line then
    best_line = math.min(target_display, math.max(1, #display.lines))
  end

  vim.api.nvim_win_set_cursor(s.windows.diff, { best_line, 0 })
  diff_state.set_pending_jump(nil)
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

  for display_lnum, new_lnum in pairs(display.all_line_map) do
    if new_lnum >= line_start and new_lnum <= line_end then
      result[display_lnum] = display.all_lines[display_lnum]
    end
  end

  local keys = {}
  for k in pairs(result) do table.insert(keys, k) end
  table.sort(keys)

  local code_lines = {}
  for _, k in ipairs(keys) do
    local line = result[k]
    local ltype = get_line_type(line)
    if ltype == "+" or ltype == "-" or ltype == " " then
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

  vim.keymap.set("v", km.note, function()
    local display = diff_state.get()
    local vstart = vim.fn.line("v")
    local vend = vim.fn.line(".")
    if vstart > vend then vstart, vend = vend, vstart end

    local lnum_start = display.line_map[vstart]
    local lnum_end = display.line_map[vend]
    if not lnum_start then return end
    lnum_end = lnum_end or lnum_start

    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end

    local code = M.get_code_context(lnum_start, lnum_end)
    require("codereview.ui.note_float").open(file.path, lnum_start, lnum_end, code)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end, opts)

  vim.keymap.set("n", km.next_note, function()
    M._jump_note(1)
  end, opts)
  vim.keymap.set("n", km.prev_note, function()
    M._jump_note(-1)
  end, opts)

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

  if km.save then
    vim.keymap.set("n", km.save, function()
      require("codereview.review.exporter").save_with_prompt()
    end, opts)
  end

  vim.keymap.set("n", km.notes_picker, function()
    require("codereview.telescope").open_notes_picker()
  end, opts)

  vim.keymap.set("n", km.toggle_virtual_text, function()
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    virtual.toggle(s.buffers.diff, file.path, diff_state.get())
  end, opts)

  vim.keymap.set("n", km.load_more_diff, function()
    M.load_more()
  end, opts)

  vim.keymap.set("n", km.cycle_focus, function()
    layout.focus_explorer()
  end, opts)

  vim.keymap.set("n", km.quit, function()
    local note_float = require("codereview.ui.note_float")
    if note_float.is_open() then
      note_float.close()
      return
    end
    layout.safe_close(false)
  end, opts)

  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)
end

function M._jump_note(direction)
  local s = state.get()
  local store = require("codereview.notes.store")
  local file = s.files[s.current_file_idx]
  if not file then return end

  local notes = store.get_for_file(file.path)
  local current_lnum = M.get_current_lnum() or 0
  local target_note = nil

  -- Search in current file first
  if direction > 0 then
    for _, note in ipairs(notes) do
      if note.line_start > current_lnum then
        target_note = note
        break
      end
    end
  else
    for i = #notes, 1, -1 do
      if notes[i].line_start < current_lnum then
        target_note = notes[i]
        break
      end
    end
  end

  if target_note then
    M.jump_to_line(target_note.line_start)
    return
  end

  -- No match in current file — search other files
  local num_files = #s.files
  if num_files <= 1 then
    -- Only one file: wrap within it (original behavior)
    if #notes > 0 then
      local wrap_note = direction > 0 and notes[1] or notes[#notes]
      M.jump_to_line(wrap_note.line_start)
    end
    return
  end

  local explorer = require("codereview.ui.explorer.actions")
  for offset = 1, num_files - 1 do
    local next_idx = ((s.current_file_idx - 1 + direction * offset) % num_files) + 1
    local next_file = s.files[next_idx]
    if next_file then
      local next_notes = store.get_for_file(next_file.path)
      if #next_notes > 0 then
        local target = direction > 0 and next_notes[1] or next_notes[#next_notes]
        explorer.preview_action({ type = "file", idx = next_idx }, { move_cursor = true })
        M.jump_to_line(target.line_start)
        return
      end
    end
  end

  -- No notes in any other file: wrap within current file
  if #notes > 0 then
    local wrap_note = direction > 0 and notes[1] or notes[#notes]
    M.jump_to_line(wrap_note.line_start)
  end
end

-- Reset diff display state (call when closing the layout)
function M.clear()
  diff_request_id = diff_request_id + 1
  reset_display()
  _ts_lang_cache = {}
  _hl_cache = {}
end

-- Refresh notes display
function M.refresh_notes()
  local s = state.get()
  local buf = s.buffers.diff
  local file = s.files[s.current_file_idx]
  if not file or not buf then return end
  if s.notes_visible then
    virtual.render_notes(buf, file.path, diff_state.get())
  else
    virtual.clear_extmarks(buf)
  end
end

return M
