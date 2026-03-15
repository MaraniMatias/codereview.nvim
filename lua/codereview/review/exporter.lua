local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")

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

-- Generate the markdown review content
function M.generate()
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
			-- Anchor: `file:line` or `file:start-end`, with (deleted) for old-side
			local side = note.side or "new"
			local side_suffix = side == "old" and " (deleted)" or ""
			if note.line_start == note.line_end then
				table.insert(lines, "`" .. note.filepath .. ":" .. note.line_start .. side_suffix .. "`")
			else
				table.insert(
					lines,
					"`" .. note.filepath .. ":" .. note.line_start .. "-" .. note.line_end .. side_suffix .. "`"
				)
			end
			table.insert(lines, "")

			-- Code block (visual selection, or auto-read from disk)
			local code = note.code
			if (not code or code == "") and side ~= "old" then
				code = read_lines(root .. "/" .. note.filepath, note.line_start - ctx, note.line_end + ctx)
			end

			if code and code ~= "" then
				table.insert(lines, "````text")
				for code_line in (code .. "\n"):gmatch("([^\n]*)\n") do
					table.insert(lines, code_line)
				end
				table.insert(lines, "````")
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
			"codereview: " .. full_path .. " already exists — use the save prompt (default keymap: <leader>s) to overwrite or rename",
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
				vim.ui.select(
					{ "Overwrite", "Rename", "Cancel" },
					{ prompt = '"' .. filename .. '" already exists:' },
					function(choice)
						if choice == "Overwrite" then
							local ok = M.save(full_path)
							if ok then
								vim.notify("Review saved to " .. full_path, vim.log.levels.INFO)
							end
							if on_save then
								on_save(ok)
							end
						elseif choice == "Rename" then
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
					end
				)
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
			vim.ui.select(
				{ "Save anyway", "Cancel" },
				{ prompt = "No notes written yet — save empty review?" },
				function(choice)
					if choice == "Save anyway" then
						M._prompt_filename(save_dir, default_name, on_save)
					else
						vim.notify("Save cancelled", vim.log.levels.INFO)
						if on_save then
							on_save(false)
						end
					end
				end
			)
		else
			M._prompt_filename(save_dir, default_name, on_save)
		end
	end)
end

return M
