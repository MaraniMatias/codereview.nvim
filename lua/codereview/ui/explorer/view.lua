local M = {}

local state          = require("codereview.state")
local explorer_state = require("codereview.ui.explorer.state")
local model          = require("codereview.ui.explorer.model")
local config         = require("codereview.config")

local explorer_ns = vim.api.nvim_create_namespace("codereview_explorer")

local function set_buffer_lines(buf, lines)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

function M.apply_highlights(buf, lines, actions_by_line, dim_by_line)
  local es = explorer_state.get()
  actions_by_line = actions_by_line or es.actions_by_line
  dim_by_line     = dim_by_line     or es.dim_by_line or {}
  vim.api.nvim_buf_clear_namespace(buf, explorer_ns, 0, -1)

  for lnum, _ in ipairs(lines) do
    local action = actions_by_line[lnum]
    if action then
      if action.type == "file" then
        local s  = state.get()
        local hl = "Normal"
        if s.files[action.idx] then
          local status = s.files[action.idx].status
          if     status == "A"            then hl = "DiffAdd"
          elseif status == "D"            then hl = "DiffDelete"
          elseif status == "M" or status == "R" then hl = "DiffChange"
          end
        end
        -- Highlight the main filename part with the status colour.
        -- In flat mode, dim_by_line[lnum] marks where the dir portion starts.
        local dim_col = dim_by_line[lnum]
        local main_end = dim_col and (dim_col - 2) or -1  -- stop before the "  " separator
        vim.api.nvim_buf_add_highlight(buf, explorer_ns, hl, lnum - 1, 0, main_end)

        -- Apply dimmed highlight to the directory portion (flat layout only).
        if dim_col then
          local path_hl = config.options.explorer_path_hl or "Comment"
          vim.api.nvim_buf_add_highlight(buf, explorer_ns, path_hl, lnum - 1, dim_col, -1)
        end
      elseif action.type == "note" then
        vim.api.nvim_buf_add_highlight(buf, explorer_ns, "Comment", lnum - 1, 0, -1)
      end
    else
      -- Tree layout: directory header rows have no action → dim them.
      if lnum > 1 then
        vim.api.nvim_buf_add_highlight(buf, explorer_ns, "Directory", lnum - 1, 0, -1)
      end
    end
  end

  -- Header row always uses Title highlight.
  vim.api.nvim_buf_add_highlight(buf, explorer_ns, "Title", 0, 0, -1)
end

function M.render()
  local s = state.get()
  local buf = s.buffers.explorer
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local rendered = model.build(s.files, s.current_file_idx)
  explorer_state.set_actions_by_line(rendered.actions_by_line)
  explorer_state.set_dim_by_line(rendered.dim_by_line)
  set_buffer_lines(buf, rendered.lines)
  M.apply_highlights(buf, rendered.lines, rendered.actions_by_line, rendered.dim_by_line)

  return rendered
end

function M.get_current_action()
  local s = state.get()
  local win = s.windows.explorer
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  return explorer_state.get().actions_by_line[lnum]
end

function M.move_cursor_to_file(idx)
  local s = state.get()
  local win = s.windows.explorer
  local buf = s.buffers.explorer
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  -- Iterate in ascending line order so we always land on the file row,
  -- not on a note sub-row that happens to share the same file index.
  -- pairs() has non-deterministic order and could match a note row first.
  local actions_by_line = explorer_state.get().actions_by_line
  local total = buf and vim.api.nvim_buf_line_count(buf) or 0
  for lnum = 1, total do
    local action = actions_by_line[lnum]
    if action and action.type == "file" and action.idx == idx then
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
      return
    end
  end
end

function M.restore_cursor(cursor)
  local s = state.get()
  local win = s.windows.explorer
  local buf = s.buffers.explorer
  if not cursor or not win or not buf then
    return
  end
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local max_lnum = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], max_lnum), cursor[2] })
end

return M
