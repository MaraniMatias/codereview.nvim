local M = {}
local state = require("codereview.state")
local config = require("codereview.config")
local diff_parser = require("codereview.diff_parser")
local split_builder = require("codereview.ui.diff_view.split")
local virtual = require("codereview.notes.virtual")
local git = require("codereview.git")
local diff_state = require("codereview.ui.diff_view.state")
local diff_ns = vim.api.nvim_create_namespace("codereview_diff")
local diff_old_ns = vim.api.nvim_create_namespace("codereview_diff_old")
local diff_request_id = 0
local _loading_idx = nil   -- tracks which file idx is currently being loaded
local treesitter_max_lines = 5000
local _ts_lang_cache = {}   -- buf -> lang string | false
local _hl_cache = {}        -- buf -> hash key string

-- Clean up caches when a buffer is deleted to prevent stale entries
vim.api.nvim_create_autocmd("BufDelete", {
  callback = function(ev)
    _ts_lang_cache[ev.buf] = nil
    _hl_cache[ev.buf] = nil
  end,
})

local function is_split_mode()
  return config.options.diff_view == "split"
end

local function update_diff_title(file)
  if not file then return end
  local s = state.get()
  if is_split_mode() then
    local old_win = s.windows.diff_old
    local new_win = s.windows.diff_new
    if old_win and vim.api.nvim_win_is_valid(old_win) then
      pcall(vim.api.nvim_win_set_config, old_win, {
        title = " old: " .. file.path .. " ",
        title_pos = "center",
      })
    end
    if new_win and vim.api.nvim_win_is_valid(new_win) then
      pcall(vim.api.nvim_win_set_config, new_win, {
        title = " new: " .. file.path .. " ",
        title_pos = "center",
      })
    end
  else
    local win = s.windows.diff
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_set_config, win, {
        title = " " .. file.path .. " ",
        title_pos = "center",
      })
    end
  end
end

local function get_line_type(l)
  return l:sub(1, 1)
end

local function reset_display()
  diff_state.reset()
  if is_split_mode() then
    diff_state.reset_old()
  end
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
  return "(diff truncated, press " .. get_load_more_key() .. " to load more)"
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
  local all_old_line_map = {}
  local all_old_to_display = {}
  local all_line_type_map = {}
  local display_lnum = 1 + header_offset

  for _, hunk in ipairs(parsed.hunks) do
    display_lnum = display_lnum + 1
    for _, l in ipairs(hunk.lines) do
      if l.new_lnum then
        all_line_map[display_lnum] = l.new_lnum
        all_new_to_display[l.new_lnum] = display_lnum
      end
      if l.old_lnum and not l.new_lnum then
        -- Deleted line: only has old_lnum
        all_old_line_map[display_lnum] = l.old_lnum
        all_old_to_display[l.old_lnum] = display_lnum
        all_line_type_map[display_lnum] = "del"
      elseif l.new_lnum and not l.old_lnum then
        all_line_type_map[display_lnum] = "add"
      elseif l.new_lnum and l.old_lnum then
        all_line_type_map[display_lnum] = "ctx"
      end
      display_lnum = display_lnum + 1
    end
  end

  return {
    all_lines = all_lines,
    all_line_types = all_line_types,
    all_line_map = all_line_map,
    all_new_to_display = all_new_to_display,
    all_old_line_map = all_old_line_map,
    all_old_to_display = all_old_to_display,
    all_line_type_map = all_line_type_map,
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

  update_diff_title(file)

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

-- Render both panels in split mode
local function render_split_display(file, opts)
  opts = opts or {}
  local s = state.get()
  local buf_old = s.buffers.diff_old
  local buf_new = s.buffers.diff_new
  local win_new = s.windows.diff_new
  local display_old = diff_state.get_old()
  local display_new = diff_state.get()

  local cursor = nil
  if opts.preserve_cursor and win_new and vim.api.nvim_win_is_valid(win_new) then
    cursor = vim.api.nvim_win_get_cursor(win_new)
  end

  -- Render old side
  if buf_old and vim.api.nvim_buf_is_valid(buf_old) then
    set_buffer_lines(buf_old, display_old.lines)
    M._apply_diff_highlights(buf_old, display_old.line_types)
    M._update_treesitter(buf_old, file and file.path, display_old.visible_until)
    if s.notes_visible and file then
      virtual.render_notes_for_side(buf_old, file.path, display_old, "old")
    else
      virtual.clear_extmarks(buf_old)
    end
  end

  -- Render new side
  if buf_new and vim.api.nvim_buf_is_valid(buf_new) then
    set_buffer_lines(buf_new, display_new.lines)
    M._apply_diff_highlights(buf_new, display_new.line_types)
    M._update_treesitter(buf_new, file and file.path, display_new.visible_until)
    if s.notes_visible and file then
      virtual.render_notes_for_side(buf_new, file.path, display_new, "new")
    else
      virtual.clear_extmarks(buf_new)
    end
  end

  update_diff_title(file)

  -- Sync scroll
  pcall(vim.cmd, "syncbind")

  if opts.cursor_lnum and win_new and vim.api.nvim_win_is_valid(win_new) then
    set_window_cursor(win_new, buf_new, opts.cursor_lnum, 0)
    return
  end

  if cursor and win_new and vim.api.nvim_win_is_valid(win_new) then
    set_window_cursor(win_new, buf_new, cursor[1], cursor[2])
    return
  end

  if opts.focus_top then
    focus_top(win_new)
  end
end

local function set_visible_until(visible_until, opts)
  local s = state.get()
  local file = s.files[s.current_file_idx]
  local display = diff_state.get()

  if not file then return false end

  local clamped_visible_until = math.max(0, math.min(visible_until, #display.all_lines))
  if clamped_visible_until == display.visible_until then
    return false
  end

  if is_split_mode() then
    local buf_old = s.buffers.diff_old
    local buf_new = s.buffers.diff_new
    if (not buf_old or not vim.api.nvim_buf_is_valid(buf_old))
      and (not buf_new or not vim.api.nvim_buf_is_valid(buf_new)) then
      return false
    end
    diff_state.set_visible_until_both(clamped_visible_until)
    render_split_display(file, opts)
  else
    local buf = s.buffers.diff
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
    diff_state.set_visible_until(clamped_visible_until)
    render_current_display(buf, file, opts)
  end
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
  local file = s.files[idx]

  -- Determine primary buffer for validation
  local primary_buf
  if is_split_mode() then
    primary_buf = s.buffers.diff_new
  else
    primary_buf = s.buffers.diff
  end

  if not file or not primary_buf or not vim.api.nvim_buf_is_valid(primary_buf) then return end

  -- Prevent re-triggering a load that is already in progress for this file
  if _loading_idx == idx then return end

  -- Helper to get the primary focus window
  local function get_focus_win()
    if is_split_mode() then return s.windows.diff_new end
    return s.windows.diff
  end

  -- Helper to set placeholder on all diff buffers
  local function set_placeholder(lines)
    if is_split_mode() then
      local buf_old = s.buffers.diff_old
      local buf_new = s.buffers.diff_new
      if buf_old and vim.api.nvim_buf_is_valid(buf_old) then
        virtual.clear_extmarks(buf_old)
        set_buffer_lines(buf_old, lines)
      end
      if buf_new and vim.api.nvim_buf_is_valid(buf_new) then
        virtual.clear_extmarks(buf_new)
        set_buffer_lines(buf_new, lines)
      end
    else
      virtual.clear_extmarks(primary_buf)
      set_buffer_lines(primary_buf, lines)
    end
  end

  -- Short-circuit for binary files: show placeholder without loading diff
  if file.is_binary then
    _loading_idx = nil
    s.current_file_idx = idx
    diff_request_id = diff_request_id + 1
    reset_display()
    set_placeholder({ "  (binary file -- diff not available)" })
    update_diff_title(file)
    focus_top(get_focus_win())
    return
  end

  _loading_idx = idx
  s.current_file_idx = idx
  diff_request_id = diff_request_id + 1
  local request_id = diff_request_id

  reset_display()
  set_placeholder({ "  (loading diff...)" })
  _hl_cache[primary_buf] = nil
  if is_split_mode() and s.buffers.diff_old then
    _hl_cache[s.buffers.diff_old] = nil
  end
  update_diff_title(file)
  focus_top(get_focus_win())

  M._get_diff_for_file(file, function(diff_text)
    if request_id ~= diff_request_id then return end
    _loading_idx = nil
    if not primary_buf or not vim.api.nvim_buf_is_valid(primary_buf) then return end

    local current_state = state.get()

    if diff_text == nil then
      reset_display()
      set_placeholder({ "  (failed to load diff)" })
      focus_top(get_focus_win())
      return
    end

    if diff_text == "" then
      reset_display()
      set_placeholder({ "  (no changes)" })
      focus_top(get_focus_win())
      return
    end

    local parsed = diff_parser.parse(diff_text)
    local limits = get_diff_limits()
    local truncation_line = get_truncation_line()

    if is_split_mode() then
      local split_display = split_builder.build_split_display(parsed)
      local visible_until = get_initial_visible_until(split_display.new.all_line_types, limits.max_diff_lines)

      diff_state.set_new({
        all_lines = split_display.new.all_lines,
        all_line_types = split_display.new.all_line_types,
        all_line_map = split_display.new.all_line_map,
        all_lnum_to_display = split_display.new.all_lnum_to_display,
        all_line_type_map = split_display.new.all_line_type_map,
        visible_until = visible_until,
        truncation_line = truncation_line,
      })

      diff_state.set_old({
        all_lines = split_display.old.all_lines,
        all_line_types = split_display.old.all_line_types,
        all_line_map = split_display.old.all_line_map,
        all_lnum_to_display = split_display.old.all_lnum_to_display,
        all_line_type_map = split_display.old.all_line_type_map,
        visible_until = visible_until,
        truncation_line = truncation_line,
      })

      render_split_display(file)
    else
      local full_display = build_full_display(parsed)

      diff_state.set({
        all_lines = full_display.all_lines,
        all_line_types = full_display.all_line_types,
        all_line_map = full_display.all_line_map,
        all_new_to_display = full_display.all_new_to_display,
        all_old_line_map = full_display.all_old_line_map,
        all_old_to_display = full_display.all_old_to_display,
        all_line_type_map = full_display.all_line_type_map,
        visible_until = get_initial_visible_until(full_display.all_line_types, limits.max_diff_lines),
        truncation_line = truncation_line,
      })

      render_current_display(primary_buf, file)
    end

    local pending_jump_lnum = diff_state.get().pending_jump_lnum
    if pending_jump_lnum then
      M.jump_to_line(pending_jump_lnum)
    else
      focus_top(get_focus_win())
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

local function _hash_line_types(line_types)
  local h = 0
  for i, ltype in ipairs(line_types) do
    -- djb2-style hash: combine index and first byte of type string
    h = ((h * 33) + i + (ltype:byte(1) or 0)) % 0x7FFFFFFF
  end
  return #line_types .. ":" .. h
end

function M._apply_diff_highlights(buf, line_types)
  local new_key = _hash_line_types(line_types)
  if _hl_cache[buf] == new_key then return end

  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  vim.api.nvim_set_hl(0, "CodeReviewFileHdr", { link = "Label", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewInfo", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewPad", { link = "NonText", default = true })

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
    elseif ltype == "pad" then
      hl = "CodeReviewPad"
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
    -- In split mode, also check old side
    if is_split_mode() then
      local display_old = diff_state.get_old()
      if not display_old.is_truncated then return end
    else
      return
    end
  end

  local limits = get_diff_limits()
  set_visible_until(display.visible_until + limits.diff_page_size, { preserve_cursor = true })
end

-- Jump to the display line nearest to new_lnum
function M.jump_to_line(new_lnum)
  local s = state.get()
  local display = diff_state.get()
  local jump_win = is_split_mode() and s.windows.diff_new or s.windows.diff

  if not jump_win or not vim.api.nvim_win_is_valid(jump_win) then
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

  vim.api.nvim_win_set_cursor(jump_win, { best_line, 0 })
  diff_state.set_pending_jump(nil)
end

-- Get the new_lnum for the current cursor position in diff view
function M.get_current_lnum()
  local s = state.get()
  if is_split_mode() then
    -- In split mode, check which window has focus
    local current_win = vim.api.nvim_get_current_win()
    if current_win == s.windows.diff_new then
      local display = diff_state.get()
      local cursor = vim.api.nvim_win_get_cursor(current_win)
      return display.line_map[cursor[1]]
    elseif current_win == s.windows.diff_old then
      local display_old = diff_state.get_old()
      local cursor = vim.api.nvim_win_get_cursor(current_win)
      return display_old.line_map[cursor[1]]
    end
    return nil
  end

  local display = diff_state.get()
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(s.windows.diff)
  return display.line_map[cursor[1]]
end

-- Extract code context from a line_map (shared by new and old side)
local function _extract_code_context(line_start, line_end, line_map, all_lines)
  local result = {}
  line_end = line_end or line_start

  for display_lnum, lnum in pairs(line_map) do
    if lnum >= line_start and lnum <= line_end then
      result[display_lnum] = all_lines[display_lnum]
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

-- Get code context for lines start..end (visual selection or single line)
function M.get_code_context(line_start, line_end)
  local display = diff_state.get()
  return _extract_code_context(line_start, line_end, display.all_line_map, display.all_lines)
end

-- Get code context from old-side display (split mode)
function M.get_code_context_old_split(line_start, line_end)
  local display_old = diff_state.get_old()
  return _extract_code_context(line_start, line_end, display_old.all_line_map, display_old.all_lines)
end

-- Get line info for the current cursor position: { lnum, side, type }
function M.get_current_line_info()
  local s = state.get()

  if is_split_mode() then
    local current_win = vim.api.nvim_get_current_win()
    if current_win == s.windows.diff_new then
      local display = diff_state.get()
      local cursor = vim.api.nvim_win_get_cursor(current_win)
      local display_lnum = cursor[1]
      local lnum = display.line_map[display_lnum]
      if lnum then
        return { lnum = lnum, side = "new", type = display.line_type_map[display_lnum] or "ctx" }
      end
      return nil
    elseif current_win == s.windows.diff_old then
      local display_old = diff_state.get_old()
      local cursor = vim.api.nvim_win_get_cursor(current_win)
      local display_lnum = cursor[1]
      local lnum = display_old.line_map[display_lnum]
      if lnum then
        local ltype = display_old.line_type_map[display_lnum] or "ctx"
        local side = (ltype == "del") and "old" or "old"
        return { lnum = lnum, side = side, type = ltype }
      end
      return nil
    end
    return nil
  end

  local display = diff_state.get()
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(s.windows.diff)
  local display_lnum = cursor[1]

  local new_lnum = display.line_map[display_lnum]
  if new_lnum then
    return { lnum = new_lnum, side = "new", type = display.line_type_map[display_lnum] or "ctx" }
  end

  local old_lnum = display.old_line_map[display_lnum]
  if old_lnum then
    return { lnum = old_lnum, side = "old", type = "del" }
  end

  return nil
end

-- Get code context for deleted (old-side) lines
function M.get_code_context_old(line_start, line_end)
  local display = diff_state.get()
  return _extract_code_context(line_start, line_end, display.all_old_line_map, display.all_lines)
end

-- Dispatch to the right code context getter based on side
function M.get_code_context_for_side(line_start, line_end, side)
  if side == "old" then
    if is_split_mode() then
      return M.get_code_context_old_split(line_start, line_end)
    end
    return M.get_code_context_old(line_start, line_end)
  end
  return M.get_code_context(line_start, line_end)
end

-- Jump to the display line nearest to old_lnum (deleted lines)
function M.jump_to_old_line(old_lnum)
  local s = state.get()

  if is_split_mode() then
    -- In split mode, old lines are in the old-side display
    local display_old = diff_state.get_old()
    local jump_win = s.windows.diff_old
    if not jump_win or not vim.api.nvim_win_is_valid(jump_win) then return end
    if #display_old.all_lines == 0 then return end

    local target = display_old.all_old_to_display[old_lnum]
      or find_best_display_line(display_old.all_old_to_display, old_lnum)
    if not target then return end

    ensure_display_line_visible(target, { preserve_cursor = true })
    display_old = diff_state.get_old()
    local best = display_old.old_to_display[old_lnum]
      or find_best_display_line(display_old.old_to_display, old_lnum)
    if not best then
      best = math.min(target, math.max(1, #display_old.lines))
    end
    vim.api.nvim_win_set_cursor(jump_win, { best, 0 })
    return
  end

  local display = diff_state.get()
  if not s.windows.diff or not vim.api.nvim_win_is_valid(s.windows.diff) then return end
  if #display.all_lines == 0 then return end

  local target_display = display.all_old_to_display[old_lnum] or find_best_display_line(display.all_old_to_display, old_lnum)
  if not target_display then return end

  ensure_display_line_visible(target_display, { preserve_cursor = true })

  display = diff_state.get()
  local best_line = display.old_to_display[old_lnum] or find_best_display_line(display.old_to_display, old_lnum)
  if not best_line then
    best_line = math.min(target_display, math.max(1, #display.lines))
  end

  vim.api.nvim_win_set_cursor(s.windows.diff, { best_line, 0 })
end

-- Jump to a line by side
function M.jump_to_line_sided(lnum, side)
  if side == "old" then
    M.jump_to_old_line(lnum)
  else
    M.jump_to_line(lnum)
  end
end

-- Setup keymaps for the diff buffer
function M.setup_keymaps(buf)
  local cfg = config.options
  local km = cfg.keymaps
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  vim.keymap.set("n", km.note, function()
    local info = M.get_current_line_info()
    if not info then return end
    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end
    local existing = require("codereview.notes.store").get(file.path, info.lnum, info.side)
    local code = M.get_code_context_for_side(info.lnum, info.lnum, info.side)
    require("codereview.ui.note_float").open(file.path, info.lnum, info.lnum, code, existing and existing.text, info.side)
  end, opts)

  vim.keymap.set("v", km.note, function()
    local vstart = vim.fn.line("v")
    local vend = vim.fn.line(".")
    if vstart > vend then vstart, vend = vend, vstart end

    local s = state.get()
    local file = s.files[s.current_file_idx]
    if not file then return end

    local side, lnum_start, lnum_end

    if is_split_mode() then
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

    local code = M.get_code_context_for_side(lnum_start, lnum_end, side)
    require("codereview.ui.note_float").open(file.path, lnum_start, lnum_end, code, nil, side)
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
    if is_split_mode() then
      virtual.toggle_split(s.buffers.diff_old, s.buffers.diff_new, file.path, diff_state.get_old(), diff_state.get())
    else
      virtual.toggle(s.buffers.diff, file.path, diff_state.get())
    end
  end, opts)

  vim.keymap.set("n", km.load_more_diff, function()
    M.load_more()
  end, opts)

  vim.keymap.set("n", km.cycle_focus, function()
    if layout.is_split_mode() and layout.is_diff_old_focused() then
      layout.focus_diff_new()
    else
      layout.focus_explorer()
    end
  end, opts)

  vim.keymap.set("n", km.quit, function()
    local note_float = require("codereview.ui.note_float")
    if note_float.is_open() then
      note_float.ask_save_or_discard()
      return
    end
    layout.safe_close(false)
  end, opts)

  layout.setup_quit_handlers(buf)
  layout.setup_write_handlers(buf)
end

local function get_note_display_pos(note, display)
  local side = note.side or "new"
  if side == "old" then
    return display.all_old_to_display[note.line_start]
  end
  return display.all_new_to_display[note.line_start]
end

function M._jump_note(direction)
  local s = state.get()
  local store = require("codereview.notes.store")
  local file = s.files[s.current_file_idx]
  if not file then return end

  local display = diff_state.get()
  local notes = store.get_for_file(file.path)

  -- Get current display position for comparison
  local current_display_pos = 0
  local active_win = is_split_mode() and s.windows.diff_new or s.windows.diff
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    current_display_pos = vim.api.nvim_win_get_cursor(active_win)[1]
  end

  local target_note = nil

  -- Search in current file first, comparing by display position
  if direction > 0 then
    local best_pos = math.huge
    for _, note in ipairs(notes) do
      local pos = get_note_display_pos(note, display)
      if pos and pos > current_display_pos and pos < best_pos then
        best_pos = pos
        target_note = note
      end
    end
  else
    local best_pos = -1
    for _, note in ipairs(notes) do
      local pos = get_note_display_pos(note, display)
      if pos and pos < current_display_pos and pos > best_pos then
        best_pos = pos
        target_note = note
      end
    end
  end

  if target_note then
    M.jump_to_line_sided(target_note.line_start, target_note.side or "new")
    return
  end

  -- No match in current file — search other files
  local num_files = #s.files
  if num_files <= 1 then
    if #notes > 0 then
      local wrap_note = direction > 0 and notes[1] or notes[#notes]
      M.jump_to_line_sided(wrap_note.line_start, wrap_note.side or "new")
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
        M.jump_to_line_sided(target.line_start, target.side or "new")
        return
      end
    end
  end

  -- No notes in any other file: wrap within current file
  if #notes > 0 then
    local wrap_note = direction > 0 and notes[1] or notes[#notes]
    M.jump_to_line_sided(wrap_note.line_start, wrap_note.side or "new")
  end
end

-- Reset diff display state (call when closing the layout)
function M.clear()
  diff_request_id = diff_request_id + 1
  _loading_idx = nil
  reset_display()
  _ts_lang_cache = {}
  _hl_cache = {}
end

-- Check if we're in split mode (exposed for other modules)
function M.is_split_mode()
  return is_split_mode()
end

-- Refresh notes display
function M.refresh_notes()
  local s = state.get()
  local file = s.files[s.current_file_idx]
  if not file then return end

  if is_split_mode() then
    local buf_old = s.buffers.diff_old
    local buf_new = s.buffers.diff_new
    if s.notes_visible then
      if buf_old then virtual.render_notes_for_side(buf_old, file.path, diff_state.get_old(), "old") end
      if buf_new then virtual.render_notes_for_side(buf_new, file.path, diff_state.get(), "new") end
    else
      if buf_old then virtual.clear_extmarks(buf_old) end
      if buf_new then virtual.clear_extmarks(buf_new) end
    end
  else
    local buf = s.buffers.diff
    if not buf then return end
    if s.notes_visible then
      virtual.render_notes(buf, file.path, diff_state.get())
    else
      virtual.clear_extmarks(buf)
    end
  end
end

return M
