local M = {}

local config = require("codereview.config")

--- Compute the changed character ranges between two strings.
--- Uses common prefix/suffix stripping + Myers-like middle diff.
--- Returns two tables of {col_start, col_end} ranges (0-indexed, exclusive end)
--- for the deleted and added strings respectively.
---@param old_str string
---@param new_str string
---@return table del_ranges, table add_ranges
function M.compute_ranges(old_str, new_str)
  if old_str == new_str then
    return {}, {}
  end

  local max_len = (config.options or {}).inline_diff_max_len or 500
  if #old_str > max_len or #new_str > max_len then
    -- Entire line is "changed" — fall back to full-line highlight
    return { { 0, #old_str } }, { { 0, #new_str } }
  end

  -- Strip common prefix
  local prefix_len = 0
  local min_len = math.min(#old_str, #new_str)
  while prefix_len < min_len and old_str:byte(prefix_len + 1) == new_str:byte(prefix_len + 1) do
    prefix_len = prefix_len + 1
  end

  -- Strip common suffix (from end, not overlapping with prefix)
  local suffix_len = 0
  local max_suffix = min_len - prefix_len
  while suffix_len < max_suffix
    and old_str:byte(#old_str - suffix_len) == new_str:byte(#new_str - suffix_len) do
    suffix_len = suffix_len + 1
  end

  local old_mid_start = prefix_len
  local old_mid_end = #old_str - suffix_len
  local new_mid_start = prefix_len
  local new_mid_end = #new_str - suffix_len

  local del_ranges = {}
  local add_ranges = {}

  if old_mid_end > old_mid_start then
    table.insert(del_ranges, { old_mid_start, old_mid_end })
  end
  if new_mid_end > new_mid_start then
    table.insert(add_ranges, { new_mid_start, new_mid_end })
  end

  return del_ranges, add_ranges
end

--- Given parsed hunk lines, find paired del/add groups and compute inline ranges.
--- Returns a table: { [display_lnum] = { ranges = {{col_start, col_end}, ...} } }
--- for both unified and split modes.
---@param all_lines string[]
---@param all_line_types string[]
---@return table inline_highlights  keyed by display_lnum (1-based)
function M.compute_for_display(all_lines, all_line_types)
  local result = {}
  local n = #all_lines
  local i = 1

  while i <= n do
    local ltype = all_line_types[i]

    if ltype == "del" then
      -- Collect consecutive del lines
      local dels = {}
      local del_start = i
      while i <= n and all_line_types[i] == "del" do
        table.insert(dels, i)
        i = i + 1
      end

      -- Collect consecutive add lines that follow
      local adds = {}
      while i <= n and all_line_types[i] == "add" do
        table.insert(adds, i)
        i = i + 1
      end

      -- Pair them for inline diff
      local pairs_count = math.min(#dels, #adds)
      for p = 1, pairs_count do
        local del_line = all_lines[dels[p]]
        local add_line = all_lines[adds[p]]

        -- Strip the leading +/- prefix for comparison
        local del_content = del_line:sub(2)
        local add_content = add_line:sub(2)

        local del_ranges, add_ranges = M.compute_ranges(del_content, add_content)

        -- Offset ranges by +1 col to account for the prefix character
        if #del_ranges > 0 then
          local shifted = {}
          for _, r in ipairs(del_ranges) do
            table.insert(shifted, { r[1] + 1, r[2] + 1 })
          end
          result[dels[p]] = shifted
        end
        if #add_ranges > 0 then
          local shifted = {}
          for _, r in ipairs(add_ranges) do
            table.insert(shifted, { r[1] + 1, r[2] + 1 })
          end
          result[adds[p]] = shifted
        end
      end
    else
      i = i + 1
    end
  end

  return result
end

--- Variant for split mode where del and add are on the same display row
--- but in different panels. The caller passes paired lines directly.
---@param old_lines string[]
---@param old_line_types string[]
---@param new_lines string[]
---@param new_line_types string[]
---@return table old_highlights, table new_highlights  keyed by display_lnum (1-based)
function M.compute_for_split(old_lines, old_line_types, new_lines, new_line_types)
  local old_result = {}
  local new_result = {}
  local n = math.min(#old_lines, #new_lines)

  for i = 1, n do
    if old_line_types[i] == "del" and new_line_types[i] == "add" then
      local old_content = old_lines[i]:sub(2) -- strip "-" prefix
      local new_content = new_lines[i]:sub(2) -- strip "+" prefix

      local del_ranges, add_ranges = M.compute_ranges(old_content, new_content)

      if #del_ranges > 0 then
        local shifted = {}
        for _, r in ipairs(del_ranges) do
          table.insert(shifted, { r[1] + 1, r[2] + 1 })
        end
        old_result[i] = shifted
      end
      if #add_ranges > 0 then
        local shifted = {}
        for _, r in ipairs(add_ranges) do
          table.insert(shifted, { r[1] + 1, r[2] + 1 })
        end
        new_result[i] = shifted
      end
    end
  end

  return old_result, new_result
end

return M
