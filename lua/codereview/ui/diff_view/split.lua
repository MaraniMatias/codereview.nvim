local M = {}

-- Build aligned side-by-side display arrays from parsed diff hunks.
-- Returns { old = { lines, line_types, line_map, lnum_to_display, line_type_map },
--           new = { lines, line_types, line_map, lnum_to_display, line_type_map } }
-- Both sides always have exactly the same number of lines (padding ensures alignment).
function M.build_split_display(parsed)
  local old_lines = {}
  local old_line_types = {}
  local old_line_map = {} -- display_lnum -> old file lnum
  local old_lnum_to_display = {} -- old file lnum -> display_lnum
  local old_line_type_map = {}

  local new_lines = {}
  local new_line_types = {}
  local new_line_map = {} -- display_lnum -> new file lnum
  local new_lnum_to_display = {} -- new file lnum -> display_lnum
  local new_line_type_map = {}

  local function push(old_line, old_type, new_line, new_type)
    table.insert(old_lines, old_line)
    table.insert(old_line_types, old_type)
    table.insert(new_lines, new_line)
    table.insert(new_line_types, new_type)
  end

  -- File headers
  if parsed.old_file and parsed.new_file then
    push("--- " .. parsed.old_file, "file_hdr", "+++ " .. parsed.new_file, "file_hdr")
  end

  -- Info lines (e.g. "index abc..def 100644")
  for _, info_line in ipairs(parsed.info_lines or {}) do
    push(info_line, "info", info_line, "info")
  end

  for hunk_idx, hunk in ipairs(parsed.hunks) do
    if hunk_idx > 1 then
      push("", "sep", "", "sep")
    end
    -- Hunk header on both sides
    push(hunk.header, "hdr", hunk.header, "hdr")

    -- Process hunk lines: group consecutive del/add runs for alignment
    local i = 1
    local hunk_lines = hunk.lines
    while i <= #hunk_lines do
      local l = hunk_lines[i]

      if l.type == "ctx" then
        -- Context: appears on both sides
        local display_lnum = #old_lines + 1
        push(" " .. l.content, "ctx", " " .. l.content, "ctx")
        old_line_map[display_lnum] = l.old_lnum
        old_lnum_to_display[l.old_lnum] = display_lnum
        old_line_type_map[display_lnum] = "ctx"
        new_line_map[display_lnum] = l.new_lnum
        new_lnum_to_display[l.new_lnum] = display_lnum
        new_line_type_map[display_lnum] = "ctx"
        i = i + 1

      elseif l.type == "del" or l.type == "add" then
        -- Collect consecutive del+add group
        local dels = {}
        local adds = {}
        local j = i
        while j <= #hunk_lines and (hunk_lines[j].type == "del" or hunk_lines[j].type == "add") do
          if hunk_lines[j].type == "del" then
            table.insert(dels, hunk_lines[j])
          else
            table.insert(adds, hunk_lines[j])
          end
          j = j + 1
        end

        -- Pair dels and adds row by row, padding the shorter side
        local max_rows = math.max(#dels, #adds)
        for row = 1, max_rows do
          local display_lnum = #old_lines + 1
          local del_line = dels[row]
          local add_line = adds[row]

          if del_line and add_line then
            -- Both sides have content
            push("-" .. del_line.content, "del", "+" .. add_line.content, "add")
            old_line_map[display_lnum] = del_line.old_lnum
            old_lnum_to_display[del_line.old_lnum] = display_lnum
            old_line_type_map[display_lnum] = "del"
            new_line_map[display_lnum] = add_line.new_lnum
            new_lnum_to_display[add_line.new_lnum] = display_lnum
            new_line_type_map[display_lnum] = "add"
          elseif del_line then
            -- Only old side has content
            push("-" .. del_line.content, "del", "", "pad")
            old_line_map[display_lnum] = del_line.old_lnum
            old_lnum_to_display[del_line.old_lnum] = display_lnum
            old_line_type_map[display_lnum] = "del"
          else
            -- Only new side has content
            push("", "pad", "+" .. add_line.content, "add")
            new_line_map[display_lnum] = add_line.new_lnum
            new_lnum_to_display[add_line.new_lnum] = display_lnum
            new_line_type_map[display_lnum] = "add"
          end
        end

        i = j
      else
        i = i + 1
      end
    end
  end

  return {
    old = {
      all_lines = old_lines,
      all_line_types = old_line_types,
      all_line_map = old_line_map,
      all_lnum_to_display = old_lnum_to_display,
      all_line_type_map = old_line_type_map,
    },
    new = {
      all_lines = new_lines,
      all_line_types = new_line_types,
      all_line_map = new_line_map,
      all_lnum_to_display = new_lnum_to_display,
      all_line_type_map = new_line_type_map,
    },
  }
end

return M
