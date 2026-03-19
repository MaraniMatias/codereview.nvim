local M = {}

local store  = require("codereview.notes.store")
local config = require("codereview.config")

-- ---------------------------------------------------------------------------
-- Devicons (lazy-loaded once)
-- ---------------------------------------------------------------------------

local _devicons = nil
local function get_file_icon(path)
	if _devicons == nil then
		local ok, devicons = pcall(require, "nvim-web-devicons")
		_devicons = ok and devicons or false
	end
	if not _devicons then return "" end
	local ext = path:match("%.([^%.]+)$") or ""
	local icon = _devicons.get_icon(path, ext, { default = false })
	return icon and (icon .. " ") or ""
end

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local STATUS_ICONS = {
	M = "[M]", A = "[A]", D = "[D]",
	R = "[R]", C = "[C]", U = "[U]",
}

-- Split "dir/sub/file.lua" → dir="dir/sub/", name="file.lua".
-- Paths with no slash return dir="", name=path.
local function split_path(path)
	local dir, name = path:match("^(.*/)([^/]+)$")
	return dir or "", name or path
end

-- Full "old -> new" label used by the flat layout for renamed files.
local function rename_label_flat(file)
	local old_dir, old_name = split_path(file.old_path)
	local new_dir, new_name = split_path(file.path)
	if old_dir == new_dir then
		-- Same directory: show "old_name → new_name  dir/"
		return old_name .. " → " .. new_name, new_dir
	else
		-- Different directories: no dim, show full paths
		return file.old_path .. " → " .. file.path, nil
	end
end

-- Note sub-rows shared between both layouts.
-- Returns a list of { line, action } pairs.
-- When config.note_multiline is true each line of the note becomes its own row,
-- all sharing the same action (they all jump to the same anchor in the diff).
local function note_rows(filepath, truncate_len)
	local rows      = {}
	local multiline = config.options.note_multiline

	for _, note in ipairs(store.get_for_file(filepath)) do
		local side       = note.side or "new"
		local side_label = side == "old" and " (del)" or ""
		local action     = { type = "note", filepath = filepath, line = note.line_start, side = side }
		local prefix     = "    ⊳ L" .. note.line_start .. side_label .. ": "
		-- Indent for continuation lines: aligns under the text, not the "⊳" glyph.
		-- Fixed at 6 spaces ("    ⊳ ") so it doesn't shift with line-number width.
		local cont_indent = "      "

		if multiline then
			-- Split on real newlines and emit one row per line.
			local first = true
			for raw_line in (note.text .. "\n"):gmatch("([^\n]*)\n") do
				local trimmed = raw_line:sub(1, truncate_len)
					.. (#raw_line > truncate_len and "…" or "")
				if first then
					table.insert(rows, { line = prefix .. trimmed, action = action })
					first = false
				else
					-- Skip trailing empty lines that result from a note ending with "\n"
					if raw_line ~= "" or not (note.text:sub(-1) == "\n") then
						table.insert(rows, { line = cont_indent .. trimmed, action = action })
					end
				end
			end
		else
			-- Single-line mode: collapse newlines to spaces (original behaviour).
			local short = note.text:gsub("\n", " ")
			local text  = short:sub(1, truncate_len) .. (#short > truncate_len and "…" or "")
			table.insert(rows, { line = prefix .. text, action = action })
		end
	end
	return rows
end

-- ---------------------------------------------------------------------------
-- FLAT layout  (filename first, dim dir suffix)
--
-- ▶ [M]  foo.lua  src/components/  (3)
--                 ^^^^^^^^^^^^^^^^ dimmed
-- ---------------------------------------------------------------------------

local function build_flat(files, current_file_idx)
	local lines         = {}
	local actions_by_line = {}
	local dim_by_line   = {}
	local truncate_len  = config.options.note_truncate_len

	local total  = #files
	local header = total > 0
		and string.format("CodeReview [%d/%d]  (? help)", current_file_idx or 0, total)
		or  "CodeReview  (? help)"
	table.insert(lines, header)

	for idx, file in ipairs(files) do
		local status_icon = STATUS_ICONS[file.status] or "[?]"
		local marker      = (idx == current_file_idx) and "▶ " or "  "
		local note_count  = store.count_for_file(file.path)
		local note_marker = note_count > 0 and ("  (" .. note_count .. ")") or ""
		local binary_tag  = file.is_binary and "  [binary]" or ""
		local file_icon   = get_file_icon(file.path)

		local name, dir
		if file.status == "R" and file.old_path and file.old_path ~= "" then
			local label, rename_dir = rename_label_flat(file)
			name = file_icon .. label
			dir  = rename_dir  -- nil when dirs differ (no dim in that case)
		else
			local d, n = split_path(file.path)
			name = file_icon .. n
			dir  = d
		end

		-- Prefix before the dimmed region: "▶ [M]  foo.lua"
		local prefix = marker .. status_icon .. "  " .. name
		local dim_part = dir and (dir ~= "" and ("  " .. dir) or "") or ""

		local full_line = prefix .. dim_part .. note_marker .. binary_tag
		table.insert(lines, full_line)
		actions_by_line[#lines] = { type = "file", idx = idx }

		-- Track where the dim region starts (byte offset, 0-indexed for nvim highlight API)
		if dir and dir ~= "" then
			-- +2 for the "  " separator before dir
			dim_by_line[#lines] = math.max(0, #prefix + 2)
		end

		if file.expanded then
			for _, row in ipairs(note_rows(file.path, truncate_len)) do
				table.insert(lines, row.line)
				actions_by_line[#lines] = row.action
			end
		end
	end

	return { lines = lines, actions_by_line = actions_by_line, dim_by_line = dim_by_line }
end

-- ---------------------------------------------------------------------------
-- TREE layout  (files grouped under their parent directory)
--
-- src/components/
--   ▶ [M] foo.lua  (3)
--   [A] bar.lua
-- src/utils/
--   [D] helper.lua
-- ---------------------------------------------------------------------------

local function build_tree(files, current_file_idx)
	local lines           = {}
	local actions_by_line = {}
	local truncate_len    = config.options.note_truncate_len

	local total  = #files
	local header = total > 0
		and string.format("CodeReview [%d/%d]  (? help)", current_file_idx or 0, total)
		or  "CodeReview  (? help)"
	table.insert(lines, header)

	-- Group files by directory, preserving insertion order.
	local dir_order = {}
	local by_dir    = {}
	for idx, file in ipairs(files) do
		-- For renames use the new path's directory.
		local dir = split_path(file.path)
		if not by_dir[dir] then
			table.insert(dir_order, dir)
			by_dir[dir] = {}
		end
		table.insert(by_dir[dir], { idx = idx, file = file })
	end

	for _, dir in ipairs(dir_order) do
		-- Directory header row (no action — not selectable)
		local dir_label = dir ~= "" and dir or "(root)"
		table.insert(lines, dir_label)
		-- actions_by_line[#lines] stays nil intentionally

		for _, entry in ipairs(by_dir[dir]) do
			local idx         = entry.idx
			local file        = entry.file
			local status_icon = STATUS_ICONS[file.status] or "[?]"
			local marker      = (idx == current_file_idx) and "▶ " or "  "
			local note_count  = store.count_for_file(file.path)
			local note_marker = note_count > 0 and (" (" .. note_count .. ")") or ""
			local binary_tag  = file.is_binary and " [binary]" or ""
			local file_icon   = get_file_icon(file.path)

			local name
			if file.status == "R" and file.old_path and file.old_path ~= "" then
				local _, old_name = split_path(file.old_path)
				local _, new_name = split_path(file.path)
				name = file_icon .. old_name .. " → " .. new_name
			else
				local _, n = split_path(file.path)
				name = file_icon .. n
			end

			table.insert(lines, "  " .. marker .. status_icon .. " " .. name .. note_marker .. binary_tag)
			actions_by_line[#lines] = { type = "file", idx = idx }

			if file.expanded then
				for _, row in ipairs(note_rows(file.path, truncate_len)) do
					table.insert(lines, "  " .. row.line)
					actions_by_line[#lines] = row.action
				end
			end
		end
	end

	return { lines = lines, actions_by_line = actions_by_line, dim_by_line = {} }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.build(files, current_file_idx)
	local layout = config.options.explorer_layout or "flat"
	if layout == "tree" then
		return build_tree(files, current_file_idx)
	end
	return build_flat(files, current_file_idx)
end

return M
