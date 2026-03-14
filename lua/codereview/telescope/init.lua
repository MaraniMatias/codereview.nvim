local M = {}

function M.open_notes_picker()
  local ok, _ = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope is not installed", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local store = require("codereview.notes.store")
  local all_notes = store.get_all()

  if #all_notes == 0 then
    vim.notify("No notes added yet", vim.log.levels.INFO)
    return
  end

  local entries = {}
  for _, note in ipairs(all_notes) do
    local short_text = note.text:gsub("\n", " ")
    local display = note.filepath .. " L" .. note.line_start .. " — " ..
      short_text:sub(1, 60)
    table.insert(entries, {
      display = display,
      note = note,
    })
  end

  pickers.new({}, {
    prompt_title = "codereview Notes",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.display,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Note Preview",
      define_preview = function(self, entry)
        local note = entry.value.note
        local preview_lines = {}
        table.insert(preview_lines, "# " .. note.filepath .. " — L" .. note.line_start)
        table.insert(preview_lines, "")
        if note.code and note.code ~= "" then
          local ext = note.filepath:match("%.([^%.]+)$") or ""
          table.insert(preview_lines, "```" .. ext)
          for line in (note.code .. "\n"):gmatch("([^\n]*)\n") do
            table.insert(preview_lines, line)
          end
          table.insert(preview_lines, "```")
          table.insert(preview_lines, "")
        end
        for line in (note.text .. "\n"):gmatch("([^\n]*)\n") do
          table.insert(preview_lines, line)
        end
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_lines)
        vim.api.nvim_set_option_value("filetype", "markdown", { buf = self.state.bufnr })
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if not selection then return end
        local note = selection.value.note

        local st = require("codereview.state")
        local s = st.get()
        local explorer = require("codereview.ui.explorer")
        local diff_view = require("codereview.ui.diff_view")
        local layout = require("codereview.ui.layout")

        for fi, f in ipairs(s.files) do
          if f.path == note.filepath then
            explorer.select_file(fi)
            diff_view.show_file(fi)
            diff_view.jump_to_line(note.line_start)
            layout.focus_diff()
            break
          end
        end
      end)
      return true
    end,
  }):find()
end

return M
