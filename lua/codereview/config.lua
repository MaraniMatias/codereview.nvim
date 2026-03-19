local M = {}

M.VERSION = "0.1.0"

M.defaults = {
	diff_view = "unified", -- "unified" | "split"
	explorer_width = 30,
	border = "rounded", -- "rounded" | "single" | "double" | "solid" | "none"
	explorer_title = " Files ",
	diff_title = " Diff ",
	note_truncate_len = 30,    -- truncation of notes in explorer sub-items (chars per line)
	note_multiline = false,    -- false = collapse note to one line | true = show all lines
	note_glyph = "⊳",         -- glyph prefix for note rows in explorer; use ">" for ASCII fallback
	explorer_layout = "flat", -- "flat" (filename first + dimmed dir) | "tree" (grouped by dir)
	explorer_path_hl = "Comment", -- highlight group for the dimmed directory portion (flat mode)
	virtual_text_truncate_len = 60, -- truncation of virtual text (eol preview)
	virtual_text_max_lines = 3, -- extra lines shown below the code line (0 = eol only)
	max_diff_lines = 1200, -- initial visible diff lines before truncation
	diff_page_size = 400, -- extra diff lines to reveal per load-more action
	keymaps = {
		note = "n",
		toggle_virtual_text = "<leader>uh",
		next_note = "]n",
		prev_note = "[n",
		next_file = "]f",
		prev_file = "[f",
		cycle_focus = "<Tab>",
		save = false,
		notes_picker = "<Space>n",
		quit = "q",
		toggle_notes = "za",
		refresh = "R",
		load_more_diff = "L",
		go_to_file = "gf",
		view_file = "gF",
		toggle_hunk_fold = "za",
		toggle_layout = "t", -- toggle between flat / tree explorer layout
	},
	review = {
		default_filename = "review-%Y-%m-%d.md",
		path = nil, -- nil = git root
		context_lines = 0, -- extra lines above/below when auto-reading code from disk
	},
}

M.options = vim.deepcopy(M.defaults)

-- Valid values for enum-like options
local VALID_DIFF_VIEWS    = { unified = true, split = true }
local VALID_BORDERS       = { rounded = true, single = true, double = true, solid = true, none = true }
local VALID_EXPLORER_LAYOUTS = { flat = true, tree = true }

-- Known keymap keys, to catch typos early
local KNOWN_KEYMAP_KEYS = {
	note = true, toggle_virtual_text = true, next_note = true, prev_note = true,
	next_file = true, prev_file = true, cycle_focus = true, save = true,
	notes_picker = true, quit = true, toggle_notes = true, refresh = true,
	load_more_diff = true, go_to_file = true, view_file = true,
	toggle_hunk_fold = true, toggle_layout = true,
}

---@param opts table
local function validate(opts)
	-- Top-level scalar options
	vim.validate({
		diff_view = {
			opts.diff_view,
			function(v) return v == nil or VALID_DIFF_VIEWS[v] ~= nil end,
			'expected "unified" or "split"',
		},
		explorer_width = {
			opts.explorer_width,
			function(v) return v == nil or (type(v) == "number" and v > 0) end,
			"expected a positive number",
		},
		border = {
			opts.border,
			function(v) return v == nil or VALID_BORDERS[v] ~= nil or type(v) == "table" end,
			'expected "rounded", "single", "double", "solid", "none", or a table',
		},
		explorer_title = {
			opts.explorer_title,
			function(v) return v == nil or type(v) == "string" end,
			"expected a string",
		},
		diff_title = {
			opts.diff_title,
			function(v) return v == nil or type(v) == "string" end,
			"expected a string",
		},
		note_truncate_len = {
			opts.note_truncate_len,
			function(v) return v == nil or (type(v) == "number" and v > 0) end,
			"expected a positive number",
		},
		note_multiline = {
			opts.note_multiline,
			function(v) return v == nil or type(v) == "boolean" end,
			"expected a boolean",
		},
		note_glyph = {
			opts.note_glyph,
			function(v) return v == nil or type(v) == "string" end,
			"expected a string",
		},
		virtual_text_truncate_len = {
			opts.virtual_text_truncate_len,
			function(v) return v == nil or (type(v) == "number" and v > 0) end,
			"expected a positive number",
		},
		virtual_text_max_lines = {
			opts.virtual_text_max_lines,
			function(v) return v == nil or (type(v) == "number" and v >= 0) end,
			"expected a non-negative number",
		},
		max_diff_lines = {
			opts.max_diff_lines,
			function(v) return v == nil or (type(v) == "number" and v > 0) end,
			"expected a positive number",
		},
		diff_page_size = {
			opts.diff_page_size,
			function(v) return v == nil or (type(v) == "number" and v > 0) end,
			"expected a positive number",
		},
		explorer_layout = {
			opts.explorer_layout,
			function(v) return v == nil or VALID_EXPLORER_LAYOUTS[v] ~= nil end,
			'expected "flat" or "tree"',
		},
		explorer_path_hl = {
			opts.explorer_path_hl,
			function(v) return v == nil or type(v) == "string" end,
			"expected a string (highlight group name)",
		},
	})

	-- keymaps table
	if opts.keymaps ~= nil then
		vim.validate({ keymaps = { opts.keymaps, "table" } })
		for key, val in pairs(opts.keymaps) do
			if not KNOWN_KEYMAP_KEYS[key] then
				error(("codereview.nvim: unknown keymap key %q (typo?)"):format(key), 0)
			end
			vim.validate({
				[("keymaps.%s"):format(key)] = {
					val,
					function(v) return type(v) == "string" or v == false end,
					"expected a string or false",
				},
			})
		end
	end

	-- review sub-table
	if opts.review ~= nil then
		vim.validate({ review = { opts.review, "table" } })
		vim.validate({
			["review.default_filename"] = {
				opts.review.default_filename,
				function(v) return v == nil or type(v) == "string" end,
				"expected a string",
			},
			["review.path"] = {
				opts.review.path,
				function(v) return v == nil or type(v) == "string" end,
				"expected nil or a string",
			},
			["review.context_lines"] = {
				opts.review.context_lines,
				function(v) return v == nil or (type(v) == "number" and v >= 0) end,
				"expected a non-negative number",
			},
		})
	end
end

function M.setup(opts)
	if opts ~= nil then
		local ok, err = pcall(validate, opts)
		if not ok then
			vim.notify("codereview.nvim: invalid config — " .. err, vim.log.levels.ERROR)
			return
		end
	end
	M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
