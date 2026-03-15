local M = {}

-- FileEntry structure:
-- { path = "src/foo.js", status = "M"|"A"|"D"|"R", old_path = "src/old.js"?, expanded = false }

local initial_state = {
  mode = nil,          -- "difftool" | "review"
  root = nil,          -- git root path
  local_dir = nil,     -- old dir (difftool mode)
  remote_dir = nil,    -- new dir (difftool mode)
  diff_args = {},      -- git diff args list (review mode)
  files = {},          -- list of FileEntry
  current_file_idx = 1,
  notes = {},          -- notes[filepath][line] = NoteEntry
  notes_dirty = false, -- true if there are unsaved notes
  single_file_difftool = false, -- true when git difftool runs without --dir-diff
  notes_visible = true, -- true if virtual text is shown in diff
  windows = {          -- window IDs
    explorer = nil,
    diff = nil,        -- unified mode
    diff_old = nil,    -- split mode (old/left side)
    diff_new = nil,    -- split mode (new/right side)
  },
  buffers = {          -- buffer IDs
    explorer = nil,
    diff = nil,        -- unified mode
    diff_old = nil,    -- split mode (old/left side)
    diff_new = nil,    -- split mode (new/right side)
  },
  ui = {
    explorer = {
      actions_by_line = {},
      last_preview_key = nil,
    },
    diff_old = {       -- split mode: old/left side display state
      lines = {},
      line_types = {},
      line_map = {},
      new_to_display = {},
      all_lines = {},
      all_line_types = {},
      all_line_map = {},
      all_new_to_display = {},
      all_old_line_map = {},
      all_old_to_display = {},
      all_line_type_map = {},
      old_line_map = {},
      old_to_display = {},
      line_type_map = {},
      visible_extmarks = {},
      visible_until = 0,
      is_truncated = false,
      truncation_line = nil,
      pending_jump_lnum = nil,
    },
    diff = {
      lines = {},
      line_types = {},
      line_map = {},
      new_to_display = {},
      all_lines = {},
      all_line_types = {},
      all_line_map = {},
      all_new_to_display = {},
      all_old_line_map = {},
      all_old_to_display = {},
      all_line_type_map = {},
      old_line_map = {},
      old_to_display = {},
      line_type_map = {},
      visible_extmarks = {},
      visible_until = 0,
      is_truncated = false,
      truncation_line = nil,
      pending_jump_lnum = nil,
    },
  },
  prev_win = nil,
  tab = nil,
}

M.state = vim.deepcopy(initial_state)

function M.init()
  M.state = vim.deepcopy(initial_state)
end

function M.get()
  return M.state
end

function M.reset()
  M.state = vim.deepcopy(initial_state)
end

return M
