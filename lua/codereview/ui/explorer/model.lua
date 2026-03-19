local M = {}

local store = require("codereview.notes.store")
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
	if not _devicons then
		return ""
	end
	local ext = path:match("%.([^%.]+)$") or ""
	local icon = _devicons.get_icon(path, ext, { default = false })
	return icon and (icon .. " ") or ""
end

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- default status icons; users can override with explorer_status_icons config.
local DEFAULT_STATUS_ICONS = {
	M = "~",
	A = "+",
	D = "-",
	R = "→",
	C = "+",
	U = "?",
}

local function get_status_icons()
	local custom = config.options.explorer_status_icons
	if custom then
		return vim.tbl_extend("force", DEFAULT_STATUS_ICONS, custom)
	end
	return DEFAULT_STATUS_ICONS
end

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
	local rows = {}
	local multiline = config.options.note_multiline

	for _, note in ipairs(store.get_for_file(filepath)) do
		local side = note.side or "new"
		local side_label = side == "old" and " (del)" or ""
		local action = { type = "note", filepath = filepath, line = note.line_start, side = side }
		local prefix = "   L" .. note.line_start .. side_label .. ": "
		-- Indent for continuation lines: aligns under the text, not the glyph.
		local cont_indent = "     "

		if multiline then
			-- Split on real newlines and emit one row per line.
			local first = true
			for raw_line in (note.text .. "\n"):gmatch("([^\n]*)\n") do
				local trimmed = raw_line:sub(1, truncate_len) .. (#raw_line > truncate_len and "…" or "")
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
			-- Single-line mode: show only the first line of the note.
			local first_line = note.text:match("^([^\n]*)") or ""
			local has_more = note.text:find("\n") ~= nil
			local text = first_line:sub(1, truncate_len) .. (#first_line > truncate_len and "…" or (has_more and " …" or ""))
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
	local lines = {}
	local actions_by_line = {}
	local dim_by_line = {}
	-- track where note_marker/binary_tag start so we can highlight them
	-- separately instead of letting them fall inside the dim region.
	local tag_ranges = {} -- lnum → { col_start, col_end }[]
	local truncate_len = config.options.note_truncate_len
	local STATUS_ICONS = get_status_icons()

	-- E06/E16: build header with optional help hint
	local total = #files
	local help_hint = config.options.explorer_show_help ~= false and "  (? help)" or ""
	local header = total > 0 and string.format("CodeReview [%d/%d]" .. help_hint, current_file_idx or 0, total)
		or ("CodeReview" .. help_hint)
	table.insert(lines, header)

	-- separator between header and file list
	table.insert(lines, "")

	-- empty state message when there are no files
	if total == 0 then
		table.insert(lines, "  No files changed")
		return { lines = lines, actions_by_line = actions_by_line, dim_by_line = dim_by_line, tag_ranges = tag_ranges }
	end

	for idx, file in ipairs(files) do
		local status_icon = STATUS_ICONS[file.status] or "[?]"
		-- use a fixed-width marker so alignment is stable regardless
		-- of whether ▶ is multibyte.  "▶ " vs "  " both occupy 2 cells,
		-- but we pad with strdisplaywidth to be safe.
		local marker = " "
		local note_count = store.count_for_file(file.path)
		local note_marker = note_count > 0 and (" (" .. note_count .. ")") or ""
		local binary_tag = file.is_binary and " [binary]" or ""
		local file_icon = get_file_icon(file.path)

		local name, dir
		if file.status == "R" and file.old_path and file.old_path ~= "" then
			local label, rename_dir = rename_label_flat(file)
			name = file_icon .. label
			dir = rename_dir -- nil when dirs differ (no dim in that case)
		else
			local d, n = split_path(file.path)
			name = file_icon .. n
			dir = d
		end

		local prefix = marker .. status_icon .. " " .. name

		-- root files (dir == "") get a dim "./" indicator
		local dir_display = dir
		if dir ~= nil and dir == "" then
			dir_display = "./"
		end

		-- configurable separator between filename and dir path
		local sep = config.options.explorer_path_separator or "  "
		local dim_part = dir_display and (dir_display ~= "" and (sep .. dir_display) or "") or ""

		-- Build line: prefix + dim_part + tags (note_marker, binary_tag come AFTER dim)
		local full_line = prefix .. dim_part .. note_marker .. binary_tag

		-- truncate with ellipsis if line exceeds explorer panel width
		local exp_width = config.options.explorer_width or 30
		if vim.fn.strdisplaywidth(full_line) > exp_width then
			-- Truncate the dim_part to fit, keeping prefix + tags intact
			local avail = exp_width - vim.fn.strdisplaywidth(prefix .. note_marker .. binary_tag) - 1 -- -1 for "…"
			if avail > 0 and dir_display and dir_display ~= "" then
				local truncated_dir = vim.fn.strcharpart(sep .. dir_display, 0, avail)
				dim_part = truncated_dir .. "…"
				full_line = prefix .. dim_part .. note_marker .. binary_tag
			end
		end
		table.insert(lines, full_line)
		actions_by_line[#lines] = { type = "file", idx = idx }

		-- Track where the dim region starts (byte offset, 0-indexed for nvim highlight API)
		-- E01 fix: dim only covers the dir portion, NOT the trailing tags.
		if dir_display and dir_display ~= "" then
			local dim_start = #prefix -- byte where "  dir/" starts (0-indexed == byte count)
			local dim_end = #prefix + #dim_part -- byte where dir portion ends
			dim_by_line[#lines] = { col_start = math.max(0, dim_start), col_end = dim_end }
		end

		-- record tag positions so view.lua can highlight them with main color
		if note_marker ~= "" or binary_tag ~= "" then
			local tag_start = #prefix + #dim_part
			local ranges = {}
			if note_marker ~= "" then
				table.insert(ranges, { col_start = tag_start, col_end = tag_start + #note_marker })
				tag_start = tag_start + #note_marker
			end
			if binary_tag ~= "" then
				table.insert(ranges, { col_start = tag_start, col_end = tag_start + #binary_tag })
			end
			tag_ranges[#lines] = ranges
		end

		if file.expanded then
			for _, row in ipairs(note_rows(file.path, truncate_len)) do
				table.insert(lines, row.line)
				actions_by_line[#lines] = row.action
			end
		end
	end

	return { lines = lines, actions_by_line = actions_by_line, dim_by_line = dim_by_line, tag_ranges = tag_ranges }
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
	local lines = {}
	local actions_by_line = {}
	local truncate_len = config.options.note_truncate_len
	local STATUS_ICONS = get_status_icons()

	-- E06/E16: build header with optional help hint
	local total = #files
	local help_hint = config.options.explorer_show_help ~= false and "  (? help)" or ""
	local header = total > 0 and string.format("CodeReview [%d/%d]" .. help_hint, current_file_idx or 0, total)
		or ("CodeReview" .. help_hint)
	table.insert(lines, header)

	-- separator between header and file list
	table.insert(lines, "")

	-- empty state message when there are no files
	if total == 0 then
		table.insert(lines, "  No files changed")
		return { lines = lines, actions_by_line = actions_by_line, dim_by_line = {} }
	end

	-- Group files by directory, preserving insertion order.
	local dir_order = {}
	local by_dir = {}
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
		-- use "./" instead of "(root)" to avoid ambiguity
		local dir_label = dir ~= "" and dir or "./"
		table.insert(lines, dir_label)
		-- actions_by_line[#lines] stays nil intentionally

		for _, entry in ipairs(by_dir[dir]) do
			local idx = entry.idx
			local file = entry.file
			local status_icon = STATUS_ICONS[file.status] or "[?]"
			local marker = " "
			local note_count = store.count_for_file(file.path)
			local note_marker = note_count > 0 and (" (" .. note_count .. ")") or ""
			local binary_tag = file.is_binary and " [binary]" or ""
			local file_icon = get_file_icon(file.path)

			local name
			if file.status == "R" and file.old_path and file.old_path ~= "" then
				local _, old_name = split_path(file.old_path)
				local _, new_name = split_path(file.path)
				name = file_icon .. old_name .. " → " .. new_name
			else
				local _, n = split_path(file.path)
				name = file_icon .. n
			end

			table.insert(lines, marker .. status_icon .. " " .. name .. note_marker .. binary_tag)
			actions_by_line[#lines] = { type = "file", idx = idx }

			if file.expanded then
				for _, row in ipairs(note_rows(file.path, truncate_len)) do
					-- note_rows already have 4-space indent; add minimal tree
					-- indent ("  ") instead of nesting deeper with the dir path.
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
