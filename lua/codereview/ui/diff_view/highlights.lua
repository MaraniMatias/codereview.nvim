local M = {}

local config = require("codereview.config")

local diff_ns = vim.api.nvim_create_namespace("codereview_diff")
local diff_old_ns = vim.api.nvim_create_namespace("codereview_diff_old")
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

function M.apply_diff_highlights(buf, line_types)
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

return M
