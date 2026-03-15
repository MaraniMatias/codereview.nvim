local M = {}

M.defaults = {
  diff_view = "unified",     -- "unified" | "split"
  explorer_width = 30,
  note_truncate_len = 30,        -- truncation of notes in explorer sub-items
  virtual_text_truncate_len = 60, -- truncation of virtual text
  keymaps = {
    note = "n",
    toggle_virtual_text = "<leader>uh",
    next_note = "]n",
    prev_note = "[n",
    next_file = "]f",
    prev_file = "[f",
    cycle_focus = "<Tab>",
    save = "<C-s>",
    notes_picker = "<Space>n",
    quit = "q",
    toggle_notes = "za",
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
