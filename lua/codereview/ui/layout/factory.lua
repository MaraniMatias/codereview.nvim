local M = {}

local config = require("codereview.config")
local buf_util = require("codereview.util.buf")

function M.compute_layout()
  local cfg = config.options
  local total_w = vim.o.columns
  local total_h = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus > 0 and 1 or 0)
  local exp_w = cfg.explorer_width
  local h = total_h - 2  -- top + bottom border

  -- Guard against terminals too narrow for the layout (L01).
  -- In split mode we need at least explorer + 2 diff panels + borders.
  local min_width = config.is_split_mode() and (exp_w + 2 + 20 + 2 + 20) or (exp_w + 2 + 24)
  if total_w < min_width then
    -- Auto-shrink explorer to fit; clamp at 10 columns minimum.
    exp_w = math.max(10, total_w - (config.is_split_mode() and 44 or 26))
    if total_w < (config.is_split_mode() and 54 or 36) then
      vim.api.nvim_echo(
        {{ "CodeReview: terminal too narrow (" .. total_w .. " cols). Layout may be broken.", "WarningMsg" }},
        true, {}
      )
    end
  end

  if config.is_split_mode() then
    -- 3-panel: explorer | diff_old | diff_new
    local diff_area_col = exp_w + 2
    local diff_area_w = total_w - diff_area_col
    local half_w = math.floor((diff_area_w - 2) / 2) -- -2 for border between panels
    local old_w = math.max(half_w, 10)
    local new_col = diff_area_col + old_w + 2
    local new_w = math.max(total_w - new_col - 2, 10)
    return {
      explorer = { row = 0, col = 0, width = math.max(exp_w, 10), height = math.max(h, 5) },
      diff_old = { row = 0, col = diff_area_col, width = old_w, height = math.max(h, 5) },
      diff_new = { row = 0, col = new_col, width = new_w, height = math.max(h, 5) },
    }
  end

  -- Unified: 2-panel explorer | diff
  local diff_col = exp_w + 2
  local diff_w = total_w - diff_col - 2
  return {
    explorer = { row = 0, col = 0, width = math.max(exp_w, 10), height = math.max(h, 5) },
    diff = { row = 0, col = diff_col, width = math.max(diff_w, 20), height = math.max(h, 5) },
  }
end

function M.create_explorer_buffer()
  return buf_util.create("codereview://explorer", { filetype = "codereview-explorer" })
end

function M.create_diff_buffer()
  return buf_util.create("codereview://diff")
end

function M.create_diff_old_buffer()
  return buf_util.create("codereview://diff-old")
end

function M.create_diff_new_buffer()
  return buf_util.create("codereview://diff-new")
end

function M.configure_panel_window(win)
  buf_util.set_win_options(win, {
    wrap = false,
    cursorline = true,
  })
end

return M
