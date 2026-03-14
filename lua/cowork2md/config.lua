local M = {}

M.defaults = {
  diff_view = "unified",     -- "unified" | "split"
  explorer_width = 30,
  keymaps = {
    add_note = "i",
    edit_note = "I",
    next_note = "]n",
    prev_note = "[n",
    next_file = "]f",
    prev_file = "[f",
    save = "<C-s>",
    notes_picker = "<Space>n",
    quit = "q",
    toggle_notes = "<Tab>",
    refresh = "R",
  },
  review = {
    default_filename = "review-%Y-%m-%d.md",
    path = nil,  -- nil = git root
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
