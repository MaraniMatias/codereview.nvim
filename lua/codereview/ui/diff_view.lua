local M = {}
local state = require("codereview.state")
local config = require("codereview.config")
local diff_parser = require("codereview.diff_parser")
local split_builder = require("codereview.ui.diff_view.split")
local virtual = require("codereview.notes.virtual")
local git = require("codereview.git")
local diff_state = require("codereview.ui.diff_view.state")
local valid = require("codereview.util.validate")
local buf_util = require("codereview.util.buf")
local highlights = require("codereview.ui.diff_view.highlights")
local diff_keymaps = require("codereview.ui.diff_view.keymaps")
local diff_ns = highlights.get_diff_ns()
local diff_old_ns = highlights.get_diff_old_ns()
local diff_request_id = 0
local _loading_idx = nil   -- tracks which file idx is currently being loaded

-- center placeholder messages in the diff panel instead of hardcoded padding
local function placeholder_line(msg)
  local s = state.get()
  local width
  if config.is_split_mode() then
    local win = s.windows.diff_new
    width = valid.win(win) and vim.api.nvim_win_get_width(win) or 40
  else
    local win = s.windows.diff
    width = valid.win(win) and vim.api.nvim_win_get_width(win) or 40
  end
  local pad = math.max(0, math.floor((width - #msg) / 2))
  return string.rep(" ", pad) .. msg
end

local function update_diff_title(file)
  if not file then return end
  local s = state.get()
  if config.is_split_mode() then
    local old_win = s.windows.diff_old
    local new_win = s.windows.diff_new
    local old_title_path = (file.old_path and file.old_path ~= "") and file.old_path or file.path
    if valid.win(old_win) then
      pcall(vim.api.nvim_win_set_config, old_win, {
        title = " old: " .. old_title_path .. " ",
        title_pos = "center",
      })
    end
    if valid.win(new_win) then
      pcall(vim.api.nvim_win_set_config, new_win, {
        title = " new: " .. file.path .. " ",
        title_pos = "center",
      })
    end
  else
    local win = s.windows.diff
    if valid.win(win) then
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
  if config.is_split_mode() then
    diff_state.reset_old()
  end
end

local function set_buffer_lines(buf, lines)
  if not valid.buf(buf) then return end
  buf_util.set_lines(buf, lines)
end

local function focus_top(win)
  if valid.win(win) then
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
end

local function set_window_cursor(win, buf, row, col)
  if not valid.win(win) then
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

  if opts.preserve_cursor and valid.win(win) then
    cursor = vim.api.nvim_win_get_cursor(win)
  end

  set_buffer_lines(buf, display.lines)
  highlights.apply_diff_highlights(buf, display.line_types)
  highlights.update_treesitter(buf, file and file.path, display.visible_until)

  if s.notes_visible and file then
    virtual.render_notes(buf, file.path, display)
  else
    virtual.clear_extmarks(buf)
  end

  update_diff_title(file)

  if opts.cursor_lnum and valid.win(win) then
    set_window_cursor(win, buf, opts.cursor_lnum, 0)
    return
  end

  if cursor and valid.win(win) then
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
  if opts.preserve_cursor and valid.win(win_new) then
    cursor = vim.api.nvim_win_get_cursor(win_new)
  end

  -- Render old side
  if valid.buf(buf_old) then
    set_buffer_lines(buf_old, display_old.lines)
    highlights.apply_diff_highlights(buf_old, display_old.line_types)
    highlights.update_treesitter(buf_old, file and file.path, display_old.visible_until)
    if s.notes_visible and file then
      virtual.render_notes_for_side(buf_old, file.path, display_old, "old")
    else
      virtual.clear_extmarks(buf_old)
    end
  end

  -- Render new side
  if valid.buf(buf_new) then
    set_buffer_lines(buf_new, display_new.lines)
    highlights.apply_diff_highlights(buf_new, display_new.line_types)
    highlights.update_treesitter(buf_new, file and file.path, display_new.visible_until)
    if s.notes_visible and file then
      virtual.render_notes_for_side(buf_new, file.path, display_new, "new")
    else
      virtual.clear_extmarks(buf_new)
    end
  end

  update_diff_title(file)

  -- Sync scroll
  pcall(vim.cmd, "syncbind")

  if opts.cursor_lnum and valid.win(win_new) then
    set_window_cursor(win_new, buf_new, opts.cursor_lnum, 0)
    return
  end

  if cursor and valid.win(win_new) then
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

  if config.is_split_mode() then
    local buf_old = s.buffers.diff_old
    local buf_new = s.buffers.diff_new
    if not valid.buf(buf_old) and not valid.buf(buf_new) then
      return false
    end
    diff_state.set_visible_until_both(clamped_visible_until)
    render_split_display(file, opts)
  else
    local buf = s.buffers.diff
    if not valid.buf(buf) then return false end
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
  if config.is_split_mode() then
    primary_buf = s.buffers.diff_new
  else
    primary_buf = s.buffers.diff
  end

  if not file or not valid.buf(primary_buf) then return end

  -- Prevent re-triggering a load that is already in progress for this file
  if _loading_idx == idx then return end

  -- Helper to get the primary focus window
  local function get_focus_win()
    if config.is_split_mode() then return s.windows.diff_new end
    return s.windows.diff
  end

  -- Helper to set placeholder on all diff buffers
  local function set_placeholder(lines)
    if config.is_split_mode() then
      local buf_old = s.buffers.diff_old
      local buf_new = s.buffers.diff_new
      if valid.buf(buf_old) then
        virtual.clear_extmarks(buf_old)
        set_buffer_lines(buf_old, lines)
      end
      if valid.buf(buf_new) then
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
    set_placeholder({ placeholder_line("(binary file -- diff not available)") })
    update_diff_title(file)
    focus_top(get_focus_win())
    return
  end

  _loading_idx = idx
  s.current_file_idx = idx
  diff_request_id = diff_request_id + 1
  local request_id = diff_request_id

  -- Stop treesitter on all diff buffers before replacing content to prevent
  -- stale treesitter callbacks from the previous file (D10 race condition).
  if config.is_split_mode() then
    if s.buffers.diff_old then
      pcall(vim.treesitter.stop, s.buffers.diff_old)
      highlights.invalidate_buf(s.buffers.diff_old)
    end
    if s.buffers.diff_new then
      pcall(vim.treesitter.stop, s.buffers.diff_new)
      highlights.invalidate_buf(s.buffers.diff_new)
    end
  else
    pcall(vim.treesitter.stop, primary_buf)
    highlights.invalidate_buf(primary_buf)
  end

  reset_display()
  set_placeholder({ placeholder_line("(loading diff...)") })
  highlights.invalidate_buf(primary_buf)
  if config.is_split_mode() and s.buffers.diff_old then
    highlights.invalidate_buf(s.buffers.diff_old)
  end
  update_diff_title(file)
  focus_top(get_focus_win())

  M._get_diff_for_file(file, function(diff_text)
    if request_id ~= diff_request_id then return end
    _loading_idx = nil
    if not valid.buf(primary_buf) then return end

    local current_state = state.get()

    if diff_text == nil then
      reset_display()
      set_placeholder({ placeholder_line("(failed to load diff)") })
      focus_top(get_focus_win())
      return
    end

    if diff_text == "" then
      reset_display()
      set_placeholder({ placeholder_line("(no changes)") })
      focus_top(get_focus_win())
      return
    end

    local parsed = diff_parser.parse(diff_text)
    local limits = get_diff_limits()
    local truncation_line = get_truncation_line()

    if config.is_split_mode() then
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

function M.load_more()
  local display = diff_state.get()
  if not display.is_truncated then
    -- In split mode, also check old side
    if config.is_split_mode() then
      local display_old = diff_state.get_old()
      if not display_old.is_truncated then
        -- notify user that diff is fully loaded
        vim.api.nvim_echo({ { "CodeReview: diff fully loaded", "Comment" } }, false, {})
        return
      end
    else
      -- notify user that diff is fully loaded
      vim.api.nvim_echo({ { "CodeReview: diff fully loaded", "Comment" } }, false, {})
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
  local jump_win = config.is_split_mode() and s.windows.diff_new or s.windows.diff

  if not valid.win(jump_win) then
    diff_state.set_pending_jump(new_lnum)
    return
  end

  if #display.all_lines == 0 then
    diff_state.set_pending_jump(new_lnum)
    return
  end

  -- D08 fix: use all_new_to_display to find the target and expand pagination,
  -- then re-read display and use new_to_display consistently for the final
  -- cursor position.  This avoids inconsistencies between the two maps.
  local target_display = display.all_new_to_display[new_lnum] or find_best_display_line(display.all_new_to_display, new_lnum)
  if not target_display then
    diff_state.set_pending_jump(nil)
    return
  end

  ensure_display_line_visible(target_display, { preserve_cursor = true })

  -- Re-read after potential pagination expansion
  display = diff_state.get()
  -- Use new_to_display (visible subset) for final position; fall back to
  -- all_new_to_display clamped to visible range for robustness.
  local best_line = display.new_to_display[new_lnum] or find_best_display_line(display.new_to_display, new_lnum)
  if not best_line then
    -- Fallback: clamp the all_ target to visible line count
    best_line = math.min(target_display, math.max(1, #display.lines))
  end

  vim.api.nvim_win_set_cursor(jump_win, { best_line, 0 })
  diff_state.set_pending_jump(nil)
end

-- Get the new_lnum for the current cursor position in diff view
function M.get_current_lnum()
  local s = state.get()
  if config.is_split_mode() then
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
  if not valid.win(s.windows.diff) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(s.windows.diff)
  return display.line_map[cursor[1]]
end

-- extract code context by iterating over all_lines sequentially instead
-- of using pairs() on line_map (non-deterministic order, unnecessary sort).
local function _extract_code_context(line_start, line_end, line_map, all_lines)
  line_end = line_end or line_start

  local code_lines = {}
  for display_lnum = 1, #all_lines do
    local lnum = line_map[display_lnum]
    if lnum and lnum >= line_start and lnum <= line_end then
      local line = all_lines[display_lnum]
      local ltype = get_line_type(line)
      if ltype == "+" or ltype == "-" or ltype == " " then
        line = line:sub(2)
      end
      table.insert(code_lines, line)
    end
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

  if config.is_split_mode() then
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
        -- old-side panel always reports side="old" regardless of line type
        local side = "old"
        return { lnum = lnum, side = side, type = ltype }
      end
      return nil
    end
    return nil
  end

  local display = diff_state.get()
  if not valid.win(s.windows.diff) then
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
    if config.is_split_mode() then
      return M.get_code_context_old_split(line_start, line_end)
    end
    return M.get_code_context_old(line_start, line_end)
  end
  return M.get_code_context(line_start, line_end)
end

-- Jump to the display line nearest to old_lnum (deleted lines)
function M.jump_to_old_line(old_lnum)
  local s = state.get()

  if config.is_split_mode() then
    -- In split mode, old lines are in the old-side display
    local display_old = diff_state.get_old()
    local jump_win = s.windows.diff_old
    if not valid.win(jump_win) then return end
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
  if not valid.win(s.windows.diff) then return end
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

-- Open the current file in a new tab, optionally jumping to the cursor line
function M._open_file_in_tab(jump_to_line)
  local s = state.get()
  local file = s.files[s.current_file_idx]
  if not file then return end

  local full_path = s.root .. "/" .. file.path
  if vim.fn.filereadable(full_path) ~= 1 then
    -- for deleted files, offer to view the version from the commit
    if file.status == "D" then
      local ref = s.diff_args and s.diff_args[1] or "HEAD"
      local cmd = "git show " .. ref .. ":" .. file.path
      vim.api.nvim_echo(
        { { "CodeReview: file deleted on disk. Opening from " .. ref .. "…", "WarningMsg" } },
        false, {}
      )
      vim.cmd("tabnew")
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
      vim.api.nvim_buf_set_name(buf, file.path .. " (" .. ref .. ")")
      local output = vim.fn.systemlist(cmd)
      if vim.v.shell_error == 0 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
        -- Try to set filetype from extension
        local ext = file.path:match("%.([^%.]+)$")
        if ext then
          local ft = vim.filetype.match({ filename = file.path }) or ext
          pcall(vim.api.nvim_set_option_value, "filetype", ft, { buf = buf })
        end
      else
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Failed to load file from " .. ref })
      end
      vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
      return
    end
    vim.api.nvim_echo(
      { { "CodeReview: file not found: " .. file.path, "WarningMsg" } },
      false, {}
    )
    return
  end

  local target_lnum = 1
  if jump_to_line then
    local info = M.get_current_line_info()
    if info and info.lnum then
      target_lnum = info.lnum
    end
  end

  -- Open in a new tab (goes to the tab before the review tab)
  vim.cmd("tabnew " .. vim.fn.fnameescape(full_path))
  pcall(vim.api.nvim_win_set_cursor, 0, { target_lnum, 0 })
  pcall(vim.cmd, "normal! zz")
end

-- Toggle fold for the hunk under the cursor
function M._toggle_hunk_fold()
  local s = state.get()
  local file = s.files[s.current_file_idx]
  if not file then return end

  -- Get cursor position in the visible buffer and map back to all_lines index
  local current_win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(current_win)
  local cursor_line = cursor[1]

  -- We need to find which all_lines hdr index corresponds to the cursor position.
  -- Walk through all_lines the same way rebuild_visible_slice does, tracking the
  -- output line index, to find the all_lines hdr_idx for the cursor's visible line.
  local display = diff_state.get()
  local folded = display.folded_hunks or {}
  local visible_until = display.visible_until
  local total_lines = #display.all_lines

  local out_idx = 0
  local src_idx = 1
  local current_hdr = nil -- the hdr all_lines index the cursor is inside

  while src_idx <= visible_until do
    local ltype = display.all_line_types[src_idx]

    if next(folded) and ltype == "hdr" and folded[src_idx] then
      -- Folded hunk: one output line
      local hunk_end_total = total_lines
      for i = src_idx + 1, total_lines do
        if display.all_line_types[i] == "hdr" then
          hunk_end_total = i - 1
          break
        end
      end
      local visible_hunk_end = math.min(hunk_end_total, visible_until)
      out_idx = out_idx + 1
      if out_idx == cursor_line then
        current_hdr = src_idx
        break
      end
      src_idx = visible_hunk_end + 1
    else
      out_idx = out_idx + 1
      if out_idx == cursor_line then
        -- Find the hdr for this line by walking backwards in all_line_types
        for i = src_idx, 1, -1 do
          if display.all_line_types[i] == "hdr" then
            current_hdr = i
            break
          end
        end
        break
      end
      src_idx = src_idx + 1
    end
  end

  if not current_hdr then return end

  if config.is_split_mode() then
    diff_state.toggle_hunk_fold_both(current_hdr)
    render_split_display(file, { preserve_cursor = true })
  else
    diff_state.toggle_hunk_fold(current_hdr)
    local buf = s.buffers.diff
    if valid.buf(buf) then
      render_current_display(buf, file, { preserve_cursor = true })
    end
  end
end

-- Setup keymaps for the diff buffer
function M.setup_keymaps(buf)
  diff_keymaps.setup(buf, M)
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

  -- Get current display position for comparison.
  -- In split mode, use the actual current window so next/prev note works
  -- correctly regardless of which panel (old/new) has focus (D11 fix).
  local current_display_pos = 0
  local active_win
  if config.is_split_mode() then
    local cur = vim.api.nvim_get_current_win()
    if cur == s.windows.diff_old or cur == s.windows.diff_new then
      active_win = cur
    else
      active_win = s.windows.diff_new
    end
  else
    active_win = s.windows.diff
  end
  if valid.win(active_win) then
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
  highlights.clear_caches()
end

-- Check if we're in split mode (exposed for other modules)
function M.is_split_mode()
  return config.is_split_mode()
end

-- Refresh notes display
function M.refresh_notes()
  local s = state.get()
  local file = s.files[s.current_file_idx]
  if not file then return end

  if config.is_split_mode() then
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
