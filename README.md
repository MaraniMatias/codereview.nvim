# CodeReview.nvim

Inline code review on any `git diff`, right inside Neovim, with export to a review file.

[![Neovim](https://img.shields.io/badge/Neovim-%3E%3D0.9-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License](https://img.shields.io/github/license/MaraniMatias/codereview.nvim)](LICENSE)

![Screenshot](./screenshot.gif)

## What you get

- **Two-panel review.** Explorer + diff side-by-side, with unified or side-by-side (`split`) views.
- **Inline notes.** Add or edit notes on any diff line, or over a visual selection. Notes show inline as virtual text, can be jumped with `]n` / `[n`, and listed via Telescope.
- **Markdown export.** `:w` prompts for a filename; `:CodeReviewWrite` saves to the auto-generated name. A one-line-per-note `table` export is available for LLM workflows.
- **Smart diff rendering.** Inline word-level highlights, gutter line numbers, optional `+`/`-` sign column, dimmed metadata, and pagination for very large diffs.
- **Two explorer layouts.** `flat` (filename first, directory dimmed) and `tree` (grouped by directory). Toggle with `t`.
- **Safety.** Unsaved-note protection on close. Notes live only in the current session until you export them.
- **Git difftool integration.** Launch with `git difftool --dir-diff` and review every changed file at once.

## Requirements

- Neovim **0.9 or newer** (Vim is not supported).
- `git` available on `PATH`.

Optional, picked up automatically when present:

- [`nvim-telescope/telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim) — enables the notes picker (`<Space>n`).
- [`nvim-tree/nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons) — file icons in the explorer.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "MaraniMatias/codereview.nvim",
  event = "VeryLazy",
  dependencies = {
    "nvim-telescope/telescope.nvim", -- optional: notes picker
    "nvim-tree/nvim-web-devicons",   -- optional: file icons
  },
  config = function()
    require("codereview").setup()
  end,
}
```

## Quick start

1. Run `:CodeReview` (or `:CodeReview main..feature`, `:CodeReview --staged`, etc.).
2. Pick a file in the explorer with `j`/`k`, press `Enter` to focus the diff.
3. Move to any diff line and press `a` to add a note. Edit later with `a` again.
4. Press `:w` to export the review as Markdown.

Press `?` in the explorer at any time to see every keymap with your current bindings.

## Commands and workflow

`CodeReview` accepts the same arguments as `git diff`:

```vim
:CodeReview                             " unstaged changes
:CodeReview main..feature               " branch comparison
:CodeReview HEAD~3                      " last 3 commits
:CodeReview --staged                    " staged changes only
:CodeReview -- path/to/file             " single file
:CodeReview --staged -- path/to/file    " staged + single file
```

### Saving and closing

| Command             | Effect                                                          |
| ------------------- | --------------------------------------------------------------- |
| `:w`                | Prompts for a filename, then writes the review when notes exist |
| `:CodeReviewWrite`  | Writes the review to the auto-generated filename when notes exist |
| `:W`                | Alias of `:CodeReviewWrite`; only registered when `W` is unused |
| `:q`                | Warns if you have unsaved notes                                 |
| `:q!`               | Same as `:q`: prompts when notes are unsaved; choose `d` to discard them or `s` to save them. |

Notes are kept in memory for the current session. With no notes, `:w`, `:CodeReviewWrite`, and `:W` do not create an empty Markdown file.

### Export formats

`review.export_format` controls the output style. Two formats are supported:

**`"default"`** — markdown with one file section, code fences that include the line numbers of your notes, and a header summarizing the diff range and counts.

````markdown
# Code Review 2026-03-14

> `main..feature` — 2 files, 3 notes

## src/foo.js

```js{10}
const result = a + b;
```

> revisit this calculation

---

```js{67,72}
function handleUser(user) {
  if (user.name) {
    return user.name;
  }
}
```

> null check `user` before `.name`
````

**`"table"`** — pipe-separated, one line per note. Compact and easy to feed to a model:

```txt
file|line|side|text
src/foo.js|10|new|revisit this calculation
src/foo.js|67-72|new|null check user before .name
```

Backslashes, pipes, and line breaks inside note fields are escaped as `\\`, `\\|`, `\\n`, and `\\r`.

## Keybindings

Most actions below can be remapped through the `keymaps` table in your `setup()`. Core explorer keys (`j`, `k`, `Enter`, `l`, `d`, `D`, `?`) are fixed to preserve standard explorer muscle memory. Press `?` in the explorer at any time to see every keymap rendered with your current bindings.

### Explorer

| Key           | Action                                         |
| ------------- | ---------------------------------------------- |
| `j` / `k`     | Navigate files and note entries                |
| `Enter` / `l` | Focus the diff panel for the selected item     |
| `]f` / `[f`   | Next or previous file                          |
| `t`           | Toggle flat / tree layout                      |
| `R`           | Refresh file list                              |
| `q`           | Close review                                   |
| `?`           | Show help window                               |

### Diff

| Key          | Action                                 |
| ------------ | -------------------------------------- |
| `a`          | Smart add or edit note on current line |
| `V` then `a` | Add note from visual selection         |
| `]n` / `[n`  | Next or previous note in current file  |
| `]f` / `[f`  | Next or previous file                  |
| `<leader>uh` | Toggle virtual text notes              |
| `<Space>n`   | Open Telescope notes picker            |
| `<Tab>`      | Focus explorer panel                   |

### Note editor

The note editor uses `:w` to save. `<Esc>` and the configured `keymaps.quit` (default `q`) ask whether to save, discard, or delete the existing note.

## Configuration

Most users do not need any config — defaults are tuned for a typical review workflow. A few common tweaks:

```lua
require("codereview").setup({
  diff_view = "split",                  -- side-by-side panels
  review = {
    path = "/tmp",                      -- an existing directory; override the git-root default
    default_filename = "review.md",
    export_format = "table",            -- pipe-separated output
  },
  keymaps = { save = "<C-s>" },         -- optional save shortcut
})
```

### Common recipes

**Side-by-side diff.** Old file on the left, new file on the right. Both panels scroll together via `scrollbind`. Notes and pagination work the same as in unified mode.

```lua
require("codereview").setup({ diff_view = "split" })
```

**LLM-friendly export.** Switch the export format to `table`. The exporter writes one line per note with `file|line|side|text`; note field values are escaped when needed.

```lua
require("codereview").setup({
  review = { export_format = "table" },
})
```

**Save to a specific directory.** `review.path` overrides the default of the git root. The directory must already exist; the exporter does not create it. The filename prompt is always constrained to a basename (no slashes).

```lua
require("codereview").setup({
  review = { path = "/tmp" },
})
```

### Diff display

CodeReview renders several enhancements by default. Set any of these to `false` to disable:

| Option                | Default | Effect                                                        |
| --------------------- | ------- | ------------------------------------------------------------- |
| `show_line_numbers`   | `true`  | Old/new line numbers in the diff gutter                       |
| `inline_diff`         | `true`  | Word-level highlight within changed lines (DiffText)          |
| `show_diff_signs`     | `false` | `+`/`-` markers in the sign column                            |
| `dim_metadata`        | `true`  | Dim `index`, `similarity`, and other diff metadata lines      |

Lines longer than `inline_diff_max_len` (default 500) fall back to full-line highlighting. Large diffs are paginated: the first `max_diff_lines` are visible, then each `L` reveals another `diff_page_size` lines.

<details>
<summary><strong>Full configuration reference</strong></summary>

```lua
require("codereview").setup({
  diff_view = "unified",            -- "unified" | "split"
  explorer_width = 30,              -- width of the file explorer panel
  border = "rounded",               -- "rounded" | "single" | "double" | "solid" | "none"
  explorer_title = " Files ",
  diff_title = " Diff ",
  note_truncate_len = 30,           -- max chars per line in explorer note sub-rows
  note_multiline = false,           -- false = collapse note to one line | true = show each line
  virtual_text_truncate_len = 60,   -- truncation of virtual text annotations
  virtual_text_max_lines = 3,       -- extra lines shown below the code line (0 = eol only)
  max_diff_lines = 1200,            -- initial visible diff lines before truncation
  diff_page_size = 400,             -- extra lines revealed per load-more action
  explorer_layout = "flat",         -- "flat" (filename first + dimmed dir) | "tree" (grouped by dir)
  explorer_path_hl = "Comment",     -- highlight group for the dimmed directory portion (flat layout)
  explorer_show_help = true,        -- show "(? help)" hint in explorer header
  explorer_path_separator = "  ",   -- separator between filename and dir in flat layout
  explorer_status_icons = nil,      -- override status icons, e.g. { M = "M", A = "A", D = "D" }
  note_count_hl = "WarningMsg",     -- highlight group for note count "(3)" in explorer
  note_float_width = 80,            -- max width for the note editor float window
  show_untracked = true,            -- show untracked files in review mode
  treesitter_max_lines = 5000,      -- disable treesitter highlighting above this line count

  -- Diff display enhancements
  show_line_numbers = true,         -- show old/new line numbers in the diff gutter
  line_number_hl = "LineNr",        -- highlight group for gutter line numbers
  inline_diff = true,               -- highlight changed characters within modified lines
  inline_diff_max_len = 500,        -- skip inline diff for lines longer than this
  show_diff_signs = false,          -- show +/- signs in the sign column
  dim_metadata = true,              -- dim diff metadata lines (index, similarity, etc.)

  keymaps = {
    note = "a",
    toggle_virtual_text = "<leader>uh",
    next_note = "]n",
    prev_note = "[n",
    next_file = "]f",
    prev_file = "[f",
    cycle_focus = "<Tab>",
    save = false,                   -- set to e.g. "<C-s>" to enable a save shortcut
    notes_picker = "<Space>n",
    quit = "q",
    toggle_notes = "za",
    toggle_layout = "t",
    refresh = "R",
    load_more_diff = "L",
    go_to_file = "gf",
    view_file = "gF",
    toggle_hunk_fold = "za",
  },

  review = {
    default_filename = "review-%Y-%m-%d.md",
    path = nil,                     -- nil = git root
    context_lines = 0,              -- extra lines above/below when auto-reading code from disk
    export_format = "default",      -- "default" | "table"
  },
})
```

</details>

<details>
<summary><strong>Git difftool integration</strong></summary>

Add this to `~/.gitconfig`:

```ini
[difftool "codereview"]
    cmd = nvim -c "lua require('codereview').difftool('$LOCAL', '$REMOTE')"
    trustExitCode = true
[difftool]
    prompt = false
```

Then run:

```bash
git difftool --dir-diff -t codereview
git difftool --dir-diff --cached -t codereview
git difftool --dir-diff -t codereview main..feature-branch
```

`--dir-diff` passes every changed file at once, enabling the multi-file explorer.

You can also point difftool at the wrapper shipped in `bin/codereview`:

```ini
[difftool "codereview"]
    cmd = /path/to/codereview/bin/codereview "$LOCAL" "$REMOTE"
    trustExitCode = true
```

The wrapper captures `$MERGED` from git's environment to build a stable, repo-relative file identity — preventing note collisions when multiple files share the same basename (for example `src/utils/helpers.js` vs `src/components/helpers.js`).

</details>

## Known limitations

- Notes are session-only. Closing CodeReview discards them unless you exported the review.
- Note anchors are based on the new-file line numbers.
- `:W` is only registered when no other plugin or user configuration already owns it. Use `:CodeReviewWrite` for the stable name.

## Acknowledgements

Inspired by _"Programar en 2026: the human-in-the-loop"_ at [JSConf ES](https://www.jsconf.es) by Javi Velasco ([@javivelasco](https://github.com/javivelasco)).
