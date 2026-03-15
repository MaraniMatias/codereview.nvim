local M = {}

local store = require("codereview.notes.store")
local config = require("codereview.config")

local _devicons = nil
local function get_file_icon(path)
  if _devicons == nil then
    local ok, devicons = pcall(require, "nvim-web-devicons")
    _devicons = ok and devicons or false
  end
  if not _devicons then
    return ""
  end
  local ext = path:match("%.([^%.]+)$") or ""
  local icon = _devicons.get_icon(path, ext, { default = false })
  return icon and (icon .. " ") or ""
end

local STATUS_ICONS = {
  M = "[M]",
  A = "[A]",
  D = "[D]",
  R = "[R]",
  C = "[C]",
  U = "[U]",
}

local function file_label(file)
  if file.status == "R" and file.old_path and file.old_path ~= "" then
    return file.old_path .. " -> " .. file.path
  end

  return file.path
end

function M.build(files, current_file_idx)
  local lines = {}
  local actions_by_line = {}
  local truncate_len = config.options.note_truncate_len
  local km = config.options.keymaps

  table.insert(lines, " CodeReview")
  table.insert(lines, " ─────────────────────────")

  for idx, file in ipairs(files) do
    local icon = STATUS_ICONS[file.status] or "[?]"
    local marker = (idx == current_file_idx) and "▶ " or "  "
    local note_count = store.count_for_file(file.path)
    local note_marker = note_count > 0 and (" (" .. note_count .. ")") or ""

    local file_icon = get_file_icon(file.path)
    table.insert(lines, marker .. icon .. " " .. file_icon .. file_label(file) .. note_marker)
    actions_by_line[#lines] = { type = "file", idx = idx }

    if file.expanded then
      local notes = store.get_for_file(file.path)
      for _, note in ipairs(notes) do
        local short = note.text:gsub("\n", " ")
        local note_line = "    ⊳ L"
          .. note.line_start
          .. ": "
          .. (short:sub(1, truncate_len) .. (#short > truncate_len and "…" or ""))
        table.insert(lines, note_line)
        actions_by_line[#lines] = {
          type = "note",
          filepath = file.path,
          line = note.line_start,
        }
      end
    end
  end

  local footer_parts = {}
  table.insert(footer_parts, "[" .. (km.quit or "q") .. "]quit")
  table.insert(footer_parts, "[" .. (km.refresh or "R") .. "]refresh")
  table.insert(footer_parts, "[" .. (km.toggle_notes or "za") .. "]notes")
  table.insert(footer_parts, "[" .. (km.next_file or "]f") .. "/" .. (km.prev_file or "[f") .. "]file")
  table.insert(footer_parts, "[" .. (km.cycle_focus or "<Tab>") .. "]focus")
  if km.save then
    table.insert(footer_parts, "[" .. km.save .. "]save")
  end

  table.insert(lines, "")
  table.insert(lines, " " .. table.concat(footer_parts, "  "))

  return {
    lines = lines,
    actions_by_line = actions_by_line,
  }
end

return M
