local M = {}

-- FileEntry structure:
-- { path = "src/foo.js", status = "M"|"A"|"D"|"R", expanded = false }

local initial_state = {
  mode = nil,          -- "difftool" | "review"
  root = nil,          -- git root path
  local_dir = nil,     -- old dir (difftool mode)
  remote_dir = nil,    -- new dir (difftool mode)
  diff_ref = nil,      -- git diff ref string (review mode)
  files = {},          -- list of FileEntry
  current_file_idx = 1,
  notes = {},          -- notes[filepath][line] = NoteEntry
  windows = {          -- window IDs
    explorer = nil,
    diff = nil,
  },
  buffers = {          -- buffer IDs
    explorer = nil,
    diff = nil,
  },
  prev_win = nil,
  tab = nil,
}

M.state = {}

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
