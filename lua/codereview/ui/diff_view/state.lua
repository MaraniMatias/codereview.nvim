local M = {}

local state = require("codereview.state")

-- ──────────────────────────────────────────────────────────────────────────────
-- Panel state factory & helpers
-- ──────────────────────────────────────────────────────────────────────────────

--- Create a fresh, empty panel state table.
---@return table
local function create_panel()
  return {
    lines = {},
    line_types = {},
    line_map = {},
    new_to_display = {},
    all_lines = {},
    all_line_types = {},
    all_line_map = {},
    all_new_to_display = {},
    all_old_line_map = {},
    all_old_to_display = {},
    all_line_type_map = {},
    old_line_map = {},
    old_to_display = {},
    line_type_map = {},
    visible_extmarks = {}, -- visible_extmarks[buf][filepath][key] = extmark_id
    visible_until = 0,
    is_truncated = false,
    truncation_line = nil,
    pending_jump_lnum = nil,
    folded_hunks = {}, -- set of all_lines indices (hdr lines) that are folded
  }
end

--- Reset every field in an existing panel state to its empty default.
---@param panel table
local function reset_panel(panel)
  panel.lines = {}
  panel.line_types = {}
  panel.line_map = {}
  panel.new_to_display = {}
  panel.all_lines = {}
  panel.all_line_types = {}
  panel.all_line_map = {}
  panel.all_new_to_display = {}
  panel.all_old_line_map = {}
  panel.all_old_to_display = {}
  panel.all_line_type_map = {}
  panel.old_line_map = {}
  panel.old_to_display = {}
  panel.line_type_map = {}
  panel.visible_extmarks = {}
  panel.visible_until = 0
  panel.is_truncated = false
  panel.truncation_line = nil
  panel.pending_jump_lnum = nil
  panel.folded_hunks = {}
end

--- Lazy-initialise and return a panel stored at `s.ui[key]`.
---@param key string  "diff" or "diff_old"
---@return table
local function ensure_panel(key)
  local s = state.get()
  s.ui = s.ui or {}
  if not s.ui[key] then
    s.ui[key] = create_panel()
  end
  return s.ui[key]
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Visible-slice builder (shared by both panels)
-- ──────────────────────────────────────────────────────────────────────────────

-- Find the end of a hunk: the line before the next "hdr" or end of data
local function find_hunk_end(all_line_types, hdr_idx, total)
  for i = hdr_idx + 1, total do
    if all_line_types[i] == "hdr" then
      return i - 1
    end
  end
  return total
end

-- Count content lines in a hunk (excluding the header itself)
local function count_hunk_lines(hdr_idx, hunk_end)
  return hunk_end - hdr_idx
end

---@param panel table  A panel state returned by ensure_panel()
local function rebuild_visible_slice(panel)
  local total_lines = #panel.all_lines
  local visible_until = math.max(0, math.min(panel.visible_until or total_lines, total_lines))

  panel.visible_until = visible_until
  panel.is_truncated = visible_until < total_lines

  local folded = panel.folded_hunks or {}
  local has_folds = next(folded) ~= nil

  local lines = {}
  local line_types = {}
  local line_map = {}
  local new_to_display = {}
  local old_line_map = {}
  local old_to_display = {}
  local line_type_map = {}

  local out_idx = 0
  local src_idx = 1

  while src_idx <= visible_until do
    local ltype = panel.all_line_types[src_idx]

    -- Check if this is a folded hunk header
    if has_folds and ltype == "hdr" and folded[src_idx] then
      local hunk_end = find_hunk_end(panel.all_line_types, src_idx, total_lines)
      local visible_hunk_end = math.min(hunk_end, visible_until)
      local hidden_count = count_hunk_lines(src_idx, visible_hunk_end)

      out_idx = out_idx + 1
      local header_text = panel.all_lines[src_idx]
      lines[out_idx] = "▸ " .. header_text .. " (" .. hidden_count .. " lines)"
      line_types[out_idx] = "hdr"
      -- Skip all lines in this hunk
      src_idx = visible_hunk_end + 1
    else
      out_idx = out_idx + 1
      lines[out_idx] = panel.all_lines[src_idx]
      line_types[out_idx] = ltype

      local new_lnum = panel.all_line_map[src_idx]
      if new_lnum then
        line_map[out_idx] = new_lnum
        new_to_display[new_lnum] = out_idx
      end

      local old_lnum = panel.all_old_line_map[src_idx]
      if old_lnum then
        old_line_map[out_idx] = old_lnum
        old_to_display[old_lnum] = out_idx
      end

      local lt = panel.all_line_type_map[src_idx]
      if lt then
        line_type_map[out_idx] = lt
      end

      src_idx = src_idx + 1
    end
  end

  if panel.is_truncated then
    out_idx = out_idx + 1
    lines[out_idx] = panel.truncation_line or "(diff truncated)"
    line_types[out_idx] = "truncated"
  end

  panel.lines = lines
  panel.line_types = line_types
  panel.line_map = line_map
  panel.new_to_display = new_to_display
  panel.old_line_map = old_line_map
  panel.old_to_display = old_to_display
  panel.line_type_map = line_type_map
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Display-data application helpers
-- ──────────────────────────────────────────────────────────────────────────────

--- Apply a display result from diff_parser or split builder onto a panel.
--- `mapping` controls which display fields map to which all_* fields.
---@param panel table
---@param display table
---@param mapping table  e.g. { new_to_display = "all_new_to_display", ... }
local function apply_display(panel, display, mapping)
  panel.all_lines = display.all_lines or {}
  panel.all_line_types = display.all_line_types or {}
  panel.all_line_map = display.all_line_map or {}
  panel.all_line_type_map = display.all_line_type_map or {}
  panel.visible_until = display.visible_until or #panel.all_lines

  -- Apply the variable field mappings
  for src_key, dest_key in pairs(mapping) do
    panel[dest_key] = display[src_key] or {}
  end

  if display.truncation_line ~= nil then
    panel.truncation_line = display.truncation_line
  end
  if display.pending_jump_lnum ~= nil then
    panel.pending_jump_lnum = display.pending_jump_lnum
  end

  rebuild_visible_slice(panel)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Extmark helpers (parameterised by panel)
-- ──────────────────────────────────────────────────────────────────────────────

---@param panel table
---@param buf number|nil
---@return table
local function extmarks_get(panel, buf)
  if buf == nil then
    return panel.visible_extmarks
  end
  panel.visible_extmarks[buf] = panel.visible_extmarks[buf] or {}
  return panel.visible_extmarks[buf]
end

---@param panel table
---@param buf number|nil
---@param filepath string|nil
---@param extmarks table|nil
local function extmarks_set(panel, buf, filepath, extmarks)
  if buf == nil or filepath == nil then return end
  local buf_extmarks = extmarks_get(panel, buf)
  if extmarks and next(extmarks) ~= nil then
    buf_extmarks[filepath] = extmarks
  else
    buf_extmarks[filepath] = nil
  end
end

---@param panel table
---@param buf number|nil
---@param filepath string|nil
local function extmarks_clear(panel, buf, filepath)
  if buf == nil then
    panel.visible_extmarks = {}
    return
  end
  if filepath == nil then
    panel.visible_extmarks[buf] = nil
    return
  end
  local buf_extmarks = panel.visible_extmarks[buf]
  if not buf_extmarks then return end
  buf_extmarks[filepath] = nil
  if next(buf_extmarks) == nil then
    panel.visible_extmarks[buf] = nil
  end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Public API — all existing callers continue to work unchanged
-- ──────────────────────────────────────────────────────────────────────────────

function M.get()
  return ensure_panel("diff")
end

function M.get_old()
  return ensure_panel("diff_old")
end

function M.reset()
  reset_panel(ensure_panel("diff"))
end

function M.reset_old()
  reset_panel(ensure_panel("diff_old"))
end

function M.set(display)
  apply_display(ensure_panel("diff"), display, {
    all_new_to_display = "all_new_to_display",
    all_old_line_map = "all_old_line_map",
    all_old_to_display = "all_old_to_display",
  })
end

-- Set new-side display for split mode (uses all_lnum_to_display from split builder)
function M.set_new(display)
  local panel = ensure_panel("diff")
  -- Clear old-side maps BEFORE rebuild so stale data from a previous set()
  -- doesn't leak into the visible slice.
  panel.all_old_line_map = {}
  panel.all_old_to_display = {}
  apply_display(panel, display, {
    all_lnum_to_display = "all_new_to_display",
  })
end

function M.set_old(display)
  local panel = ensure_panel("diff_old")
  -- Pre-set the old-side mappings so rebuild_visible_slice (called by
  -- apply_display) can see them.  In the old-side panel the line_map
  -- doubles as old_line_map and lnum_to_display as old_to_display.
  panel.all_old_line_map = display.all_line_map or {}
  panel.all_old_to_display = display.all_lnum_to_display or {}
  apply_display(panel, display, {
    all_lnum_to_display = "all_new_to_display",
  })
end

function M.set_visible_until(visible_until)
  local panel = ensure_panel("diff")
  panel.visible_until = visible_until
  rebuild_visible_slice(panel)
end

function M.set_visible_until_both(visible_until)
  local panel = ensure_panel("diff")
  panel.visible_until = visible_until
  rebuild_visible_slice(panel)
  local panel_old = ensure_panel("diff_old")
  panel_old.visible_until = visible_until
  rebuild_visible_slice(panel_old)
end

function M.set_pending_jump(new_lnum)
  local panel = ensure_panel("diff")
  panel.pending_jump_lnum = new_lnum
end

-- Extmarks: main panel (unified / new-side in split)
function M.get_visible_extmarks(buf)
  return extmarks_get(ensure_panel("diff"), buf)
end

function M.set_visible_extmarks(buf, filepath, extmarks)
  extmarks_set(ensure_panel("diff"), buf, filepath, extmarks)
end

function M.clear_visible_extmarks(buf, filepath)
  extmarks_clear(ensure_panel("diff"), buf, filepath)
end

-- Extmarks: old-side panel (split mode)
function M.get_old_visible_extmarks(buf)
  return extmarks_get(ensure_panel("diff_old"), buf)
end

function M.set_old_visible_extmarks(buf, filepath, extmarks)
  extmarks_set(ensure_panel("diff_old"), buf, filepath, extmarks)
end

function M.clear_old_visible_extmarks(buf, filepath)
  extmarks_clear(ensure_panel("diff_old"), buf, filepath)
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Hunk folding
-- ──────────────────────────────────────────────────────────────────────────────

-- Find the hunk header (all_lines index) that contains the given display line.
-- Returns the all_lines index of the hdr line, or nil.
function M.find_hunk_header_for_line(display_lnum)
  local panel = ensure_panel("diff")
  for i = display_lnum, 1, -1 do
    if panel.all_line_types[i] == "hdr" then
      return i
    end
  end
  return nil
end

-- Toggle fold state for a hunk identified by its header line index in all_lines
function M.toggle_hunk_fold(hdr_idx)
  local panel = ensure_panel("diff")
  if panel.folded_hunks[hdr_idx] then
    panel.folded_hunks[hdr_idx] = nil
  else
    panel.folded_hunks[hdr_idx] = true
  end
  rebuild_visible_slice(panel)
end

-- Toggle fold on both sides (split mode)
function M.toggle_hunk_fold_both(hdr_idx)
  local panel = ensure_panel("diff")
  local panel_old = ensure_panel("diff_old")
  local new_state = not panel.folded_hunks[hdr_idx]
  if new_state then
    panel.folded_hunks[hdr_idx] = true
    panel_old.folded_hunks[hdr_idx] = true
  else
    panel.folded_hunks[hdr_idx] = nil
    panel_old.folded_hunks[hdr_idx] = nil
  end
  rebuild_visible_slice(panel)
  rebuild_visible_slice(panel_old)
end

function M.is_hunk_folded(hdr_idx)
  local panel = ensure_panel("diff")
  return panel.folded_hunks[hdr_idx] == true
end

return M
