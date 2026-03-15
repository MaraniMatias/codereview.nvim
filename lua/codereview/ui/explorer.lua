local M = {}
local state = require("codereview.state")
local store = require("codereview.notes.store")
local config = require("codereview.config")

-- Status icons
local STATUS_ICONS = {
	M = "[M]",
	A = "[A]",
	D = "[D]",
	R = "[R]",
	C = "[C]",
	U = "[U]",
}

-- Line -> action map (rebuilt each render)
local line_actions = {}
local last_preview_key = nil

local function action_key(action)
	if not action then
		return nil
	end
	if action.type == "file" then
		return "file:" .. action.idx
	end
	if action.type == "note" then
		return "note:" .. action.filepath .. ":" .. action.line
	end
	return nil
end

local function find_file_idx(filepath)
	local s = state.get()
	for idx, file in ipairs(s.files) do
		if file.path == filepath then
			return idx
		end
	end
	return nil
end

-- Render the explorer buffer
function M.render()
	local s = state.get()
	local buf = s.buffers.explorer
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local lines = {}
	line_actions = {}

	-- Header
	table.insert(lines, " CodeReview")
	table.insert(lines, " ─────────────────────────")
	line_actions[1] = nil
	line_actions[2] = nil

	-- File list
	for idx, file in ipairs(s.files) do
		local icon = STATUS_ICONS[file.status] or "[?]"
		local marker = (idx == s.current_file_idx) and "▶ " or "  "
		local note_count = store.count_for_file(file.path)
		local note_marker = note_count > 0 and (" (" .. note_count .. ")") or ""
		local line = marker .. icon .. " " .. file.path .. note_marker
		table.insert(lines, line)
		line_actions[#lines] = { type = "file", idx = idx }

		-- Show notes as sub-items if expanded
		if file.expanded then
			local notes = store.get_for_file(file.path)
			for _, note in ipairs(notes) do
				local short = note.text:gsub("\n", " ")
				local tlen = config.options.note_truncate_len
				local note_line = "    ⊳ L"
					.. note.line_start
					.. ": "
					.. (short:sub(1, tlen) .. (#short > tlen and "…" or ""))
				table.insert(lines, note_line)
				line_actions[#lines] = { type = "note", filepath = file.path, line = note.line_start }
			end
		end
	end

	-- Footer hint
	table.insert(lines, "")
	table.insert(lines, " [q]uit  [R]efresh  <C-s>save")

	-- Write to buffer
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	-- Apply highlights
	M._apply_highlights(buf, lines)
end

function M._apply_highlights(buf, lines)
	local ns = vim.api.nvim_create_namespace("codereview_explorer")
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	for lnum, _ in ipairs(lines) do
		local action = line_actions[lnum]
		if action then
			if action.type == "file" then
				local s = state.get()
				local hl = "Normal"
				if s.files[action.idx] then
					local status = s.files[action.idx].status
					if status == "A" then
						hl = "DiffAdd"
					elseif status == "D" then
						hl = "DiffDelete"
					elseif status == "M" then
						hl = "DiffChange"
					end
				end
				vim.api.nvim_buf_add_highlight(buf, ns, hl, lnum - 1, 0, -1)
			elseif action.type == "note" then
				vim.api.nvim_buf_add_highlight(buf, ns, "Comment", lnum - 1, 0, -1)
			end
		end
	end

	-- Header highlights
	vim.api.nvim_buf_add_highlight(buf, ns, "Title", 0, 0, -1)
	vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 0, -1)
end

-- Get the action for the current cursor line
function M.get_current_action()
	local s = state.get()
	local win = s.windows.explorer
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return line_actions[lnum]
end

-- Set the selected file by index
function M.select_file(idx)
	local s = state.get()
	local opts = {}
	if type(idx) == "table" then
		opts = idx
		idx = opts.idx
	end
	if idx < 1 or idx > #s.files then
		return
	end
	if opts.move_cursor == nil then
		opts.move_cursor = true
	end

	local win = s.windows.explorer
	local cursor = nil
	if opts.preserve_cursor and win and vim.api.nvim_win_is_valid(win) then
		cursor = vim.api.nvim_win_get_cursor(win)
	end

	local changed = s.current_file_idx ~= idx
	s.current_file_idx = idx

	if changed or opts.force_render then
		M.render()
	end

	if opts.move_cursor then
		M._move_cursor_to_file(idx)
	elseif cursor and win and vim.api.nvim_win_is_valid(win) then
		local max_lnum = vim.api.nvim_buf_line_count(s.buffers.explorer)
		vim.api.nvim_win_set_cursor(win, { math.min(cursor[1], max_lnum), cursor[2] })
	end
end

function M._move_cursor_to_file(idx)
	local s = state.get()
	local win = s.windows.explorer
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	for lnum, action in pairs(line_actions) do
		if action and action.type == "file" and action.idx == idx then
			vim.api.nvim_win_set_cursor(win, { lnum, 0 })
			return
		end
	end
end

function M.preview_action(action, opts)
	opts = opts or {}
	if not action then
		return
	end

	local diff_view = require("codereview.ui.diff_view")
	local layout = require("codereview.ui.layout")

	if action.type == "file" then
		M.select_file({
			idx = action.idx,
			preserve_cursor = opts.preserve_cursor,
			move_cursor = opts.move_cursor,
		})
		diff_view.show_file(action.idx)
	elseif action.type == "note" then
		local file_idx = find_file_idx(action.filepath)
		if not file_idx then
			return
		end
		M.select_file({
			idx = file_idx,
			preserve_cursor = opts.preserve_cursor,
			move_cursor = opts.move_cursor,
		})
		diff_view.show_file(file_idx)
		diff_view.jump_to_line(action.line)
	else
		return
	end

	last_preview_key = action_key(action)

	if opts.focus_diff then
		layout.focus_diff()
	end
end

function M.preview_current(opts)
	local action = M.get_current_action()
	local key = action_key(action)
	if not key then
		last_preview_key = nil
		return
	end
	if key == last_preview_key then
		return
	end
	M.preview_action(action, opts)
end

-- Setup keymaps for the explorer buffer
function M.setup_keymaps(buf)
	local cfg = config.options
	local km = cfg.keymaps
	local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

	local function open_current()
		local action = M.get_current_action()
		if not action then
			return
		end
		M.preview_action(action, { focus_diff = true, move_cursor = true })
	end

	vim.keymap.set("n", "<CR>", open_current, opts)
	vim.keymap.set("n", "l", open_current, opts)

	-- Toggle notes expand/collapse
	vim.keymap.set("n", km.toggle_notes, function()
		local action = M.get_current_action()
		if action and action.type == "file" then
			local s = state.get()
			local file = s.files[action.idx]
			if file then
				file.expanded = not file.expanded
				M.render()
				last_preview_key = nil
				M.preview_current({ preserve_cursor = true })
			end
		end
	end, opts)

	-- Next/prev file
	vim.keymap.set("n", km.next_file, function()
		local s = state.get()
		if s.current_file_idx < #s.files then
			M.select_file(s.current_file_idx + 1)
			require("codereview.ui.diff_view").show_file(s.current_file_idx)
		end
	end, opts)

	vim.keymap.set("n", km.prev_file, function()
		local s = state.get()
		if s.current_file_idx > 1 then
			M.select_file(s.current_file_idx - 1)
			require("codereview.ui.diff_view").show_file(s.current_file_idx)
		end
	end, opts)

	-- Refresh
	vim.keymap.set("n", km.refresh, function()
		require("codereview").refresh()
	end, opts)

	-- Quit
	vim.keymap.set("n", km.quit, function()
		require("codereview.ui.layout").safe_close(false)
	end, opts)

	-- Cycle focus to diff panel
	vim.keymap.set("n", km.cycle_focus, function()
		require("codereview.ui.layout").focus_diff()
	end, opts)

	-- Save
	vim.keymap.set("n", km.save, function()
		require("codereview.review.exporter").save_with_prompt()
	end, opts)

	local layout = require("codereview.ui.layout")
	layout.setup_quit_handlers(buf)
	layout.setup_write_handlers(buf)
	vim.api.nvim_create_autocmd("CursorHold", {
		buffer = buf,
		callback = function()
			M.preview_current({ preserve_cursor = true })
		end,
	})
end

return M
