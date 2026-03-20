local M = {}

local config = require("codereview.config")
local inline_diff = require("codereview.ui.diff_view.inline_diff")

local diff_ns = vim.api.nvim_create_namespace("codereview_diff")
local diff_old_ns = vim.api.nvim_create_namespace("codereview_diff_old")
local linenr_ns = vim.api.nvim_create_namespace("codereview_linenr")
local sign_ns = vim.api.nvim_create_namespace("codereview_signs")
local _ts_lang_cache = {}
local _hl_cache = {}

-- Clean up caches when a buffer is deleted to prevent stale entries
vim.api.nvim_create_autocmd("BufDelete", {
  callback = function(ev)
    _ts_lang_cache[ev.buf] = nil
    _hl_cache[ev.buf] = nil
  end,
})

-- monotonic counter as salt to avoid hash collisions between different
-- diffs that happen to produce the same djb2 hash.
local _hash_salt = 0

local function _hash_line_types(line_types)
  _hash_salt = _hash_salt + 1
  local h = _hash_salt
  for i, ltype in ipairs(line_types) do
    -- djb2-style hash: combine index and first byte of type string
    h = ((h * 33) + i + (ltype:byte(1) or 0)) % 0x7FFFFFFF
  end
  return #line_types .. ":" .. h .. ":" .. _hash_salt
end

-- Ensure all custom highlight groups are defined
local function ensure_highlight_groups()
  vim.api.nvim_set_hl(0, "CodeReviewFileHdr", { link = "Label", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewInfo", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewPad", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewInfoDim", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSignAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewSignDel", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewLineNr", {
    link = (config.options or {}).line_number_hl or "LineNr",
    default = true,
  })
end

function M.apply_diff_highlights(buf, line_types)
  local new_key = _hash_line_types(line_types)
  if _hl_cache[buf] == new_key then return end

  vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)

  ensure_highlight_groups()

  local opts = config.options or {}
  local dim_metadata = opts.dim_metadata ~= false -- default true

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
      hl = dim_metadata and "CodeReviewInfoDim" or "CodeReviewInfo"
    end
    if hl then
      vim.api.nvim_buf_add_highlight(buf, diff_ns, hl, lnum - 1, 0, -1)
    end
  end

  _hl_cache[buf] = new_key
end

--- Apply inline (word-level) diff highlights on top of existing line highlights.
--- Uses DiffText highlight group for the changed portions within add/del lines.
---@param buf number
---@param lines string[]
---@param line_types string[]
function M.apply_inline_highlights(buf, lines, line_types)
  if not ((config.options or {}).inline_diff ~= false) then return end

  local inline_hl = inline_diff.compute_for_display(lines, line_types)

  for lnum, ranges in pairs(inline_hl) do
    for _, r in ipairs(ranges) do
      vim.api.nvim_buf_add_highlight(buf, diff_ns, "DiffText", lnum - 1, r[1], r[2])
    end
  end
end

--- Apply inline highlights for split mode (paired panels).
---@param buf_old number
---@param buf_new number
---@param old_lines string[]
---@param old_line_types string[]
---@param new_lines string[]
---@param new_line_types string[]
function M.apply_inline_highlights_split(buf_old, buf_new, old_lines, old_line_types, new_lines, new_line_types)
  if not ((config.options or {}).inline_diff ~= false) then return end

  local old_hl, new_hl = inline_diff.compute_for_split(
    old_lines, old_line_types,
    new_lines, new_line_types
  )

  for lnum, ranges in pairs(old_hl) do
    for _, r in ipairs(ranges) do
      vim.api.nvim_buf_add_highlight(buf_old, diff_ns, "DiffText", lnum - 1, r[1], r[2])
    end
  end

  for lnum, ranges in pairs(new_hl) do
    for _, r in ipairs(ranges) do
      vim.api.nvim_buf_add_highlight(buf_new, diff_ns, "DiffText", lnum - 1, r[1], r[2])
    end
  end
end

--- Apply line numbers as virtual text in the sign/gutter area.
--- Shows old_lnum and new_lnum for each line.
---@param buf number
---@param display table  panel state with line_map, old_line_map, line_types
function M.apply_line_numbers(buf, display)
  if not ((config.options or {}).show_line_numbers ~= false) then return end

  vim.api.nvim_buf_clear_namespace(buf, linenr_ns, 0, -1)

  ensure_highlight_groups()

  local line_map = display.line_map or {}
  -- Use old_lnum_display which includes ctx + del lines (not just del)
  local old_lnum_display = display.old_lnum_display or display.old_line_map or {}
  local line_types = display.line_types or {}

  -- Compute max width for alignment
  local max_old = 0
  local max_new = 0
  for _, n in pairs(old_lnum_display) do
    if n and n > max_old then max_old = n end
  end
  for _, n in pairs(line_map) do
    if n and n > max_new then max_new = n end
  end
  local old_width = math.max(3, #tostring(max_old))
  local new_width = math.max(3, #tostring(max_new))

  for lnum = 1, #(display.lines or {}) do
    local ltype = line_types[lnum]
    -- Skip non-code lines
    if ltype == "file_hdr" or ltype == "info" or ltype == "hdr"
      or ltype == "sep" or ltype == "truncated" or ltype == "pad" then
      goto continue
    end

    local old_n = old_lnum_display[lnum]
    local new_n = line_map[lnum]

    local old_str
    local new_str
    if old_n then
      old_str = string.format("%" .. old_width .. "d", old_n)
    else
      old_str = string.rep(" ", old_width)
    end
    if new_n then
      new_str = string.format("%" .. new_width .. "d", new_n)
    else
      new_str = string.rep(" ", new_width)
    end

    local virt_text = {
      { old_str .. " ", "CodeReviewLineNr" },
      { new_str .. " ", "CodeReviewLineNr" },
    }

    pcall(vim.api.nvim_buf_set_extmark, buf, linenr_ns, lnum - 1, 0, {
      virt_text = virt_text,
      virt_text_pos = "inline",
      priority = 50,
    })

    ::continue::
  end
end

--- Apply line numbers for split mode (each panel shows its own side's number).
---@param buf number
---@param display table
---@param side string  "old" or "new"
function M.apply_line_numbers_split(buf, display, side)
  if not ((config.options or {}).show_line_numbers ~= false) then return end

  vim.api.nvim_buf_clear_namespace(buf, linenr_ns, 0, -1)

  ensure_highlight_groups()

  local lnum_map
  if side == "old" then
    lnum_map = display.old_line_map or display.line_map or {}
  else
    lnum_map = display.line_map or {}
  end
  local line_types = display.line_types or {}

  -- Compute max width
  local max_n = 0
  for _, n in pairs(lnum_map) do
    if n > max_n then max_n = n end
  end
  local width = math.max(3, #tostring(max_n))

  for lnum = 1, #(display.lines or {}) do
    local ltype = line_types[lnum]
    if ltype == "file_hdr" or ltype == "info" or ltype == "hdr"
      or ltype == "sep" or ltype == "truncated" or ltype == "pad" then
      goto continue
    end

    local n = lnum_map[lnum]
    local str
    if n then
      str = string.format("%" .. width .. "d", n)
    else
      str = string.rep(" ", width)
    end

    pcall(vim.api.nvim_buf_set_extmark, buf, linenr_ns, lnum - 1, 0, {
      virt_text = { { str .. " ", "CodeReviewLineNr" } },
      virt_text_pos = "inline",
      priority = 50,
    })

    ::continue::
  end
end

--- Apply sign column markers (+/-) for diff lines.
---@param buf number
---@param line_types string[]
function M.apply_signs(buf, line_types)
  if not ((config.options or {}).show_diff_signs ~= false) then return end

  vim.api.nvim_buf_clear_namespace(buf, sign_ns, 0, -1)

  ensure_highlight_groups()

  for lnum, ltype in ipairs(line_types) do
    local sign_text
    local sign_hl
    if ltype == "add" then
      sign_text = "+"
      sign_hl = "CodeReviewSignAdd"
    elseif ltype == "del" then
      sign_text = "-"
      sign_hl = "CodeReviewSignDel"
    end
    if sign_text then
      pcall(vim.api.nvim_buf_set_extmark, buf, sign_ns, lnum - 1, 0, {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
        priority = 100,
      })
    end
  end
end

function M.update_treesitter(buf, filepath, visible_until)
  local desired_lang = nil
  local ts_max = config.options.treesitter_max_lines or 5000
  if filepath and visible_until > 0 and visible_until <= ts_max then
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

function M.clear_caches()
  _ts_lang_cache = {}
  _hl_cache = {}
end

function M.invalidate_buf(buf)
  _ts_lang_cache[buf] = nil
  _hl_cache[buf] = nil
end

function M.get_diff_ns()
  return diff_ns
end

function M.get_diff_old_ns()
  return diff_old_ns
end

function M.get_linenr_ns()
  return linenr_ns
end

function M.get_sign_ns()
  return sign_ns
end

return M
