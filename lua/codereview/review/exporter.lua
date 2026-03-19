local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")
local prompt = require("codereview.util.prompt")

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

-- Helper: resolve the first line of code for a note (used by inline/compact formats)
local function first_code_line(note, root)
	local side = note.side or "new"
	if side == "old" then
		return nil
	end
	local line = note.code
	if line and line ~= "" then
		-- note.code may be a multi-line block; take only the first line
		line = line:match("([^\n]+)") or line
	else
		line = read_lines(root .. "/" .. note.filepath, note.line_start, note.line_start)
	end
	if line then
		line = vim.trim(line)
	end
	return (line ~= "") and line or nil
end

-- Format: one entry per note, ref + inline code on one line, note text below
--
-- src/foo.js:0 `const result = a + b;`
-- revisit this calculation
--
-- handlers/user.js:67 `function handleUser(user) {`
-- null check `user` before `.name`
-- add logging for failed cases
local function generate_inline()
	local date = os.date("%Y-%m-%d")
	local lines = {}

	table.insert(lines, "# Review " .. date)
	table.insert(lines, "")

	local all_notes = store.get_all()

	if #all_notes == 0 then
		table.insert(lines, "_Write your notes here._")
		table.insert(lines, "")
	else
		local root = state.get().root or vim.fn.getcwd()

		for _, note in ipairs(all_notes) do
			local side = note.side or "new"
			local side_suffix = side == "old" and " (deleted)" or ""
			local ref = note.filepath .. side_suffix .. ":" .. note.line_start
			local code = first_code_line(note, root)

			if code then
				table.insert(lines, ref .. " `" .. code .. "`")
			else
				table.insert(lines, ref)
			end

			if note.text and note.text ~= "" then
				for text_line in (note.text .. "\n"):gmatch("([^\n]*)\n") do
					table.insert(lines, text_line)
				end
			end

			table.insert(lines, "")
		end
	end

	return table.concat(lines, "\n")
end

-- Format: one line per note — ref range — note text (newlines collapsed, no code)
--
-- src/foo.js:0-1 — revisit this calculation
-- handlers/user.js:67-72 — add null check for `user` before accessing `.name`
local function generate_compact()
	local date = os.date("%Y-%m-%d")
	local lines = {}

	table.insert(lines, "# Review " .. date)
	table.insert(lines, "")

	local all_notes = store.get_all()

	if #all_notes == 0 then
		table.insert(lines, "_Write your notes here._")
		table.insert(lines, "")
	else
		for _, note in ipairs(all_notes) do
			local side = note.side or "new"
			local side_suffix = side == "old" and " (deleted)" or ""
			local range = note.line_start .. "-" .. note.line_end
			local ref = note.filepath .. side_suffix .. ":" .. range

			local entry = ref
			if note.text and note.text ~= "" then
				local one_line = vim.trim(note.text:gsub("\n+", " "))
				entry = entry .. " - " .. one_line
			end

			table.insert(lines, entry)
		end

		table.insert(lines, "")
	end

	return table.concat(lines, "\n")
end

-- Format: full code block per note (original behaviour)
local function generate_block()
	local date = os.date("%Y-%m-%d")
	local lines = {}
	local ctx = (config.options.review and config.options.review.context_lines) or 0

	table.insert(lines, "# Review " .. date)
	table.insert(lines, "")

	local all_notes = store.get_all()

	if #all_notes == 0 then
		table.insert(lines, "_Write your notes here._")
		table.insert(lines, "")
	else
		local root = state.get().root or vim.fn.getcwd()

		for _, note in ipairs(all_notes) do
			-- Anchor: `filepath` with (deleted) for old-side
			local side = note.side or "new"
			local side_suffix = side == "old" and " (deleted)" or ""
			table.insert(lines, "`" .. note.filepath .. side_suffix .. "`")
			table.insert(lines, "")

			-- Code block (visual selection, or auto-read from disk)
			local code = note.code
			if (not code or code == "") and side ~= "old" then
				code = read_lines(root .. "/" .. note.filepath, note.line_start - ctx, note.line_end + ctx)
			end

			if code and code ~= "" then
				table.insert(lines, "```text{" .. note.line_start .. "," .. note.line_end .. "}")
				for code_line in (code .. "\n"):gmatch("([^\n]*)\n") do
					table.insert(lines, code_line)
				end
				table.insert(lines, "```")
				table.insert(lines, "")
			end

			-- Note text as plain paragraph
			if note.text and note.text ~= "" then
				for text_line in (note.text .. "\n"):gmatch("([^\n]*)\n") do
					table.insert(lines, text_line)
				end
			end

			table.insert(lines, "")
		end
	end

	return table.concat(lines, "\n")
end

-- Generate the markdown review content (dispatch by export_format)
function M.generate()
	local fmt = (config.options.review and config.options.review.export_format) or "inline"
	if fmt == "compact" then
		return generate_compact()
	elseif fmt == "block" then
		return generate_block()
	else
		return generate_inline()
	end
end

-- Save to a file
function M.save(filepath)
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
-- Warns instead of silently overwriting if the file already exists.
function M.save_direct()
	local s = state.get()
	local cfg = config.options
	local default_name = os.date(cfg.review.default_filename)
	local save_dir = normalize_dir(cfg.review.path or s.root or vim.fn.getcwd())
	local full_path = save_dir .. "/" .. default_name

	if vim.fn.filereadable(full_path) == 1 then
		vim.notify(
			"codereview: "
				.. full_path
				.. " already exists — use the save prompt (default keymap: <leader>s) to overwrite or rename",
			vim.log.levels.WARN
		)
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
-- Warns before saving an empty review, then delegates to _prompt_filename.
function M.save_with_prompt(on_save)
	local s = state.get()
	local cfg = config.options
	local save_dir = normalize_dir(cfg.review.path or s.root or vim.fn.getcwd())
	local default_name = os.date(cfg.review.default_filename)

	local all_notes = store.get_all()

	vim.schedule(function()
		if #all_notes == 0 then
			-- Warn the user that there are no notes before saving
			if prompt.confirm("No notes written yet — save empty review?") then
				M._prompt_filename(save_dir, default_name, on_save)
			else
				vim.notify("Save cancelled", vim.log.levels.INFO)
				if on_save then
					on_save(false)
				end
			end
		else
			M._prompt_filename(save_dir, default_name, on_save)
		end
	end)
end

return M
