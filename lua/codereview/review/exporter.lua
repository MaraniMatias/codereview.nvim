local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")
local prompt = require("codereview.util.prompt")

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local function read_lines(abs_path, first, last)
	local f = io.open(abs_path, "r")
	if not f then
		return nil
	end
	local all = {}
	for line in f:lines() do
		table.insert(all, line)
	end
	f:close()
	if first < 1 then
		first = 1
	end
	if last > #all then
		last = #all
	end
	if first > last then
		return nil
	end
	local slice = {}
	for i = first, last do
		table.insert(slice, all[i])
	end
	return table.concat(slice, "\n")
end

-- "42" when start==end, "42-50" when they differ
local function format_range(line_start, line_end)
	if line_start == line_end then
		return tostring(line_start)
	end
	return line_start .. "-" .. line_end
end

-- "{42}" for new-side, "{-42}" for old/deleted side; comma-separated for ranges
local function format_fence_range(line_start, line_end, side)
	local prefix = (side == "old") and "-" or ""
	if line_start == line_end then
		return "{" .. prefix .. line_start .. "}"
	end
	return "{" .. prefix .. line_start .. "," .. prefix .. line_end .. "}"
end

-- Map file extension to markdown language tag for syntax highlighting
local EXT_LANG = {
	lua = "lua", js = "js", ts = "ts", tsx = "tsx", jsx = "jsx",
	py = "python", rb = "ruby", rs = "rust", go = "go", java = "java",
	c = "c", cpp = "cpp", h = "c", hpp = "cpp", cs = "csharp",
	sh = "sh", bash = "bash", zsh = "zsh", fish = "fish",
	json = "json", yaml = "yaml", yml = "yaml", toml = "toml",
	md = "markdown", html = "html", css = "css", scss = "scss",
	sql = "sql", vim = "vim", ex = "elixir", exs = "elixir",
	kt = "kotlin", swift = "swift", php = "php", r = "r",
}

local function detect_lang(filepath)
	local ext = filepath:match("%.([^%.]+)$")
	if ext then
		return EXT_LANG[ext:lower()] or ext:lower()
	end
	return ""
end

-- Group a sorted-by-filepath list of notes into { {filepath, notes}, ... }
local function group_by_file(all_notes)
	local groups = {}
	local current_file = nil
	local current_group = nil
	for _, note in ipairs(all_notes) do
		if note.filepath ~= current_file then
			current_file = note.filepath
			current_group = { filepath = current_file, notes = {} }
			table.insert(groups, current_group)
		end
		table.insert(current_group.notes, note)
	end
	return groups
end

-- Build enriched header with git context
local function build_header(all_notes)
	local date = os.date("%Y-%m-%d")
	local lines = {}

	table.insert(lines, "# Code Review " .. date)
	table.insert(lines, "")

	-- Determine diff context label
	local s = state.get()
	local diff_label
	if s.mode == "difftool" then
		diff_label = "difftool"
	elseif s.diff_args and #s.diff_args > 0 then
		diff_label = table.concat(s.diff_args, " ")
	else
		diff_label = "working tree"
	end

	-- Count unique files from notes
	local file_set = {}
	for _, note in ipairs(all_notes) do
		file_set[note.filepath] = true
	end
	local file_count = 0
	for _ in pairs(file_set) do
		file_count = file_count + 1
	end

	local note_count = #all_notes
	local summary = string.format(
		"> `%s` — %d %s, %d %s",
		diff_label,
		file_count,
		file_count == 1 and "file" or "files",
		note_count,
		note_count == 1 and "note" or "notes"
	)
	table.insert(lines, summary)
	table.insert(lines, "")

	return lines
end

local function abort_empty_export(on_save)
	vim.notify("No notes to export", vim.log.levels.INFO)
	if on_save then
		on_save(false)
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Format: "human" — markdown with headings per file, code blocks, line refs
-- ---------------------------------------------------------------------------

local function generate_human()
	local all_notes = store.get_all()
	local lines = build_header(all_notes)

	if #all_notes == 0 then
		table.insert(lines, "_Write your notes here._")
		table.insert(lines, "")
		return table.concat(lines, "\n")
	end

	local root = state.get().root or vim.fn.getcwd()
	local ctx = (config.options.review and config.options.review.context_lines) or 0
	local groups = group_by_file(all_notes)

	for _, group in ipairs(groups) do
		table.insert(lines, "## " .. group.filepath)
		table.insert(lines, "")

		for i, note in ipairs(group.notes) do
			local side = note.side or "new"
			local lang = detect_lang(note.filepath)
			local fence_range = format_fence_range(note.line_start, note.line_end, side)

			-- Code block
			local code = note.code
			if (not code or code == "") and side ~= "old" then
				code = read_lines(root .. "/" .. note.filepath, note.line_start - ctx, note.line_end + ctx)
			end

			table.insert(lines, "```" .. lang .. fence_range)
			if code and code ~= "" then
				for code_line in (code .. "\n"):gmatch("([^\n]*)\n") do
					table.insert(lines, code_line)
				end
			end
			table.insert(lines, "```")
			table.insert(lines, "")

			-- Note text
			if note.text and note.text ~= "" then
				for text_line in (note.text .. "\n"):gmatch("([^\n]*)\n") do
					table.insert(lines, text_line)
				end
				table.insert(lines, "")
			end

			-- Separator between notes in the same file (not after the last one)
			if i < #group.notes then
				table.insert(lines, "---")
				table.insert(lines, "")
			end
		end
	end

	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Format: "llm" — TSV with header, one line per note, token-efficient
-- ---------------------------------------------------------------------------

local function generate_llm()
	local all_notes = store.get_all()

	local lines = {}
	table.insert(lines, "file|line|text")

	if #all_notes == 0 then
		return table.concat(lines, "\n") .. "\n"
	end

	for _, note in ipairs(all_notes) do
		local range = format_range(note.line_start, note.line_end)
		local side = note.side or "new"
		local filepath = note.filepath
		if side == "old" then
			filepath = filepath .. " (del)"
		end
		local text = ""
		if note.text and note.text ~= "" then
			text = vim.trim(note.text:gsub("\n+", " "))
		end
		table.insert(lines, filepath .. "|" .. range .. "|" .. text)
	end

	return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Generate the review content (dispatch by export_format)
function M.generate()
	local fmt = (config.options.review and config.options.review.export_format) or "default"
	if fmt == "table" then
		return generate_llm()
	else
		return generate_human()
	end
end

-- Save to a file
function M.save(filepath)
	if not store.has_any() then
		return abort_empty_export()
	end

	local content = M.generate()
	local f = io.open(filepath, "w")
	if not f then
		vim.notify("Error: could not write to " .. filepath, vim.log.levels.ERROR)
		return false
	end
	local ok, err = pcall(function()
		f:write(content)
		f:close()
	end)
	if not ok then
		pcall(function()
			f:close()
		end)
		vim.notify("Error: could not write to " .. filepath .. ": " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	state.get().notes_dirty = false
	return true
end

-- Strip trailing slash from a directory path
local function normalize_dir(dir)
	return (dir:gsub("/$", ""))
end

-- Validate a filename entered by the user.
-- Returns nil if valid, or an error string describing the problem.
local function validate_filename(filename)
	if vim.trim(filename) == "" then
		return "filename cannot be empty or only whitespace"
	end
	-- Block any slash: covers both absolute paths and path traversal (../)
	if filename:find("/") then
		return "filename cannot contain slashes — set review.path in your config to change the output directory"
	end
	if #filename > 255 then
		return "filename is too long (max 255 characters)"
	end
	if filename:find("%z") then
		return "filename contains invalid characters"
	end
	return nil
end

-- Save directly to auto-generated path (no prompt).
-- When the file already exists, offers overwrite / rename / cancel instead of
-- showing a passive warning.
function M.save_direct()
	if not store.has_any() then
		return abort_empty_export()
	end

	local s = state.get()
	local cfg = config.options
	local default_name = os.date(cfg.review.default_filename)
	local save_dir = normalize_dir(cfg.review.path or s.root or vim.fn.getcwd())
	local full_path = save_dir .. "/" .. default_name

	if vim.fn.filereadable(full_path) == 1 then
		vim.schedule(function()
			local choice = prompt.choose('"' .. default_name .. '" already exists:', {
				{ key = "o", label = "overwrite", value = "overwrite" },
				{ key = "r", label = "rename", value = "rename" },
				{ key = "c", label = "cancel", value = "cancel" },
			})
			if choice == "overwrite" then
				if M.save(full_path) then
					vim.notify("Review saved to " .. full_path, vim.log.levels.INFO)
				end
			elseif choice == "rename" then
				vim.schedule(function()
					M._prompt_filename(save_dir, default_name)
				end)
			end
		end)
		return
	end

	if M.save(full_path) then
		vim.notify("Review saved to " .. full_path, vim.log.levels.INFO)
	end
end

-- Internal: prompt the user for a filename, then handle conflicts with
-- an Overwrite / Rename / Cancel menu. On "Rename" the prompt loops.
function M._prompt_filename(save_dir, default_name, on_save)
	vim.ui.input({
		prompt = "Save review as: ",
		default = default_name,
	}, function(filename)
		-- nil means the user pressed <Esc> / cancelled the input
		if not filename then
			vim.notify("Save cancelled", vim.log.levels.INFO)
			if on_save then
				on_save(false)
			end
			return
		end

		filename = vim.trim(filename)

		local err = validate_filename(filename)
		if err then
			vim.notify("codereview: " .. err, vim.log.levels.ERROR)
			if on_save then
				on_save(false)
			end
			return
		end

		local full_path = save_dir .. "/" .. filename

		if vim.fn.filereadable(full_path) == 1 then
			-- File already exists: offer Overwrite / Rename / Cancel
			vim.schedule(function()
				local choice = prompt.choose('"' .. filename .. '" already exists:', {
					{ key = "o", label = "overwrite", value = "overwrite" },
					{ key = "r", label = "rename", value = "rename" },
					{ key = "c", label = "cancel", value = "cancel" },
				})
				if choice == "overwrite" then
					local ok = M.save(full_path)
					if ok then
						vim.notify("Review saved to " .. full_path, vim.log.levels.INFO)
					end
					if on_save then
						on_save(ok)
					end
				elseif choice == "rename" then
					-- Loop back with current name as new default
					vim.schedule(function()
						M._prompt_filename(save_dir, filename, on_save)
					end)
				else
					vim.notify("Save cancelled", vim.log.levels.INFO)
					if on_save then
						on_save(false)
					end
				end
			end)
		else
			local ok = M.save(full_path)
			if ok then
				vim.notify("Review saved to " .. full_path, vim.log.levels.INFO)
			end
			if on_save then
				on_save(ok)
			end
		end
	end)
end

-- Save with a vim.ui.input prompt.
-- Requires at least one note before delegating to _prompt_filename.
function M.save_with_prompt(on_save)
	local s = state.get()
	local cfg = config.options
	local save_dir = normalize_dir(cfg.review.path or s.root or vim.fn.getcwd())
	local default_name = os.date(cfg.review.default_filename)

	vim.schedule(function()
		if not store.has_any() then
			abort_empty_export(on_save)
		else
			M._prompt_filename(save_dir, default_name, on_save)
		end
	end)
end

return M
