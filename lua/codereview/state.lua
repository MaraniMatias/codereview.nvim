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
    -- diff and diff_old panels are lazily created by diff_view/state.ensure_panel()
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

function M.set_mode(mode)
  M.state.mode = mode
end

function M.set_files(files)
  M.state.files = files
end

function M.set_current_file_idx(idx)
  M.state.current_file_idx = idx
end

function M.set_root(root)
  M.state.root = root
end

function M.mark_notes_dirty()
  M.state.notes_dirty = true
end

function M.mark_notes_clean()
  M.state.notes_dirty = false
end

return M
