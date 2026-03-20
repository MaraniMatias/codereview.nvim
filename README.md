# CodeReview.nvim

Inline code review on any `git diff`, right inside Neovim and export to markdown file.

[![Neovim](https://img.shields.io/badge/Neovim-%3E%3D0.9-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License](https://img.shields.io/github/license/MaraniMatias/codereview.nvim)](LICENSE)

![Screenshot](./screenshot.gif)

## Features

**Review workflow** — Two-panel layout (explorer + diff) with unified or side-by-side split view, markdown export with prompt flow or direct `:W` save, `git difftool --dir-diff` integration.

**Inline notes** — Smart add/edit on any diff line, visual-selection notes with captured code context, virtual text with visibility toggle, Telescope picker for all notes.

**Navigation** — File explorer with badges and note counts, `]n`/`[n` and `]f`/`[f` bracket motions, `?` help window with all keymaps. Two explorer layouts: **flat** (filename first, directory dimmed) and **tree** (files grouped by directory), toggled with `t`.

**Safety** — Unsaved-note protection on close, large diff pagination with configurable thresholds.

### Export Formats

Running `:w` or `:W` generates a review file. Two formats are available via `review.export_format`:

**`"default"`** — markdown with headings per file, code blocks with syntax highlighting, and enriched header:

````markdown
# Code Review 2026-03-14

> `main..feature` — 2 files, 3 notes

## src/foo.js

```js{10}
const result = a + b;
```

revisit this calculation

---

```js{67,72}
function handleUser(user) {
  if (user.name) {
    return user.name;
  }
}
```

null check `user` before `.name`

## handlers/user.js

```js{120}
logger.info(event);
```

consider structured logging
````

**`"table"`** — pipe-separated with header, one line per note, optimized for LLM token efficiency:

```txt
file|line|side|text
src/foo.js|10|new|revisit this calculation
src/foo.js|67-72|new|null check user before .name
handlers/user.js|120|new|consider structured logging
```

## Quick Start

1. Install the plugin (see [Installation](#installation))
2. Open a review: `:CodeReview`
3. Navigate files with `j`/`k`, press `n` on any diff line to add a note, export with `:w`

## Installation

```lua
{
  "MaraniMatias/codereview.nvim",
  event = "VeryLazy",
  dependencies = {
    "nvim-telescope/telescope.nvim", -- optional: enables notes picker (<Space>n)
    "nvim-tree/nvim-web-devicons",   -- optional: file icons in the explorer
  },
  config = function()
    require("codereview").setup({})
  end,
}
```

## Usage

### Inside Neovim

`:CodeReview` accepts any arguments you would pass to `git diff`.

```vim
:CodeReview                             " unstaged changes
:CodeReview main..feature               " branch comparison
:CodeReview HEAD~3                      " last 3 commits
:CodeReview --staged                    " staged changes only
:CodeReview -- path/to/file             " single file
:CodeReview --staged -- path/to/file    " staged + single file
```

### Saving and Closing

| Command | Effect                                        |
| ------- | --------------------------------------------- |
| `:w`    | Opens save prompt, writes the markdown review |
| `:W`    | Saves directly to the auto-generated filename |
| `:q`    | Warns if you have unsaved notes               |
| `:q!`   | Forces the review tab to close                |

Notes live in memory for the current session only; exporting saves the Markdown review, not the in-editor note state.

### As git difftool

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

`--dir-diff` gives the plugin all changed files at once, enabling the multi-file explorer.

<details>
<summary>Alternative: wrapper script</summary>

You can also point difftool at the wrapper shipped in `bin/codereview`:

```ini
[difftool "codereview"]
    cmd = /path/to/codereview/bin/codereview "$LOCAL" "$REMOTE"
    trustExitCode = true
```

The wrapper automatically captures `$MERGED` from git's environment to build a stable, repo-relative file identity — preventing note collisions when multiple files share the same basename (e.g. `src/utils/helpers.js` vs `src/components/helpers.js`).

</details>

## Keybindings

All keybindings are remappable via `keymaps` in your setup config.

### Explorer Panel

| Key           | Action                                         |
| ------------- | ---------------------------------------------- |
| `j` / `k`     | Navigate files and note entries                |
| `Enter` / `l` | Focus the diff panel for the selected item     |
| `za`          | Expand or collapse notes for the selected file |
| `]f` / `[f`   | Next or previous file                          |
| `t`           | Toggle flat / tree layout                      |
| `R`           | Refresh file list                              |
| `<Tab>`       | Focus diff panel                               |
| `?`           | Show help window                               |
| `q`           | Close review                                   |

### Diff Panel

| Key          | Action                                 |
| ------------ | -------------------------------------- |
| `n`          | Smart add or edit note on current line |
| `V` then `n` | Add note from visual selection         |
| `]n` / `[n`  | Next or previous note in current file  |
| `]f` / `[f`  | Next or previous file                  |
| `L`          | Load more lines for a truncated diff   |
| `za`         | Toggle fold for the current hunk       |
| `gf`         | Open file in a new tab at cursor line  |
| `gF`         | Open full file in a new tab            |
| `<leader>uh` | Toggle virtual text notes              |
| `<Space>n`   | Open Telescope notes picker            |
| `<Tab>`      | Focus explorer panel                   |
| `q`          | Close review                           |

### Note Editor

| Key     | Action                          |
| ------- | ------------------------------- |
| `<C-s>` | Save note (normal & insert)     |
| `q`     | Discard note without asking     |
| `<Esc>` | Ask to save or discard          |
| `<C-d>` | Delete note (with confirmation) |

## Configuration

Most users won't need any config — defaults are tuned for a typical review workflow.

```lua
require("codereview").setup({
  explorer_width = 30,
  keymaps = {
    save = "<C-s>",  -- disabled by default; set to enable a save shortcut
  },
})
```

### Full configuration reference

```lua
require("codereview").setup({
  diff_view = "unified",            -- "unified" | "split" (side-by-side)
  explorer_width = 30,              -- width of the file explorer panel
  border = "rounded",               -- "rounded" | "single" | "double" | "solid" | "none"
  explorer_title = " Files ",
  diff_title = " Diff ",
  note_truncate_len = 30,           -- max chars per line in explorer note sub-rows
  note_multiline = false,           -- false = collapse note to one line | true = show each line
  note_glyph = "⊳",                -- glyph prefix for note rows; use ">" for ASCII fallback
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
  show_untracked = false,             -- show untracked files in review mode
  treesitter_max_lines = 5000,      -- disable treesitter highlighting above this line count

  keymaps = {
    note = "n",                     -- smart add/edit note on current line
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
    toggle_layout = "t",            -- toggle between flat / tree explorer layout
    refresh = "R",
    load_more_diff = "L",
    go_to_file = "gf",              -- open file in new tab at cursor line
    view_file = "gF",               -- open full file in new tab
    toggle_hunk_fold = "za",        -- fold/unfold the current hunk
  },

  review = {
    default_filename = "review-%Y-%m-%d.md",
    path = nil,                     -- nil = git root
    context_lines = 0,              -- extra lines above/below when auto-reading code from disk
    export_format = "default",      -- "default" | "table"
  },
})
```

### Split (side-by-side) view

Set `diff_view = "split"` to display diffs side by side — old file on the left, new file on the right. Both panels scroll together via Neovim's `scrollbind`. All keybindings, notes, and pagination work the same in both views.

```lua
require("codereview").setup({
  diff_view = "split",
})
```

Large diffs keep the current behavior when they fit within `max_diff_lines`. When a diff exceeds that limit, CodeReview renders the first slice, shows a truncation sentinel at the bottom, and each `load_more_diff` action reveals another `diff_page_size` lines.

## Known Limitations

- Notes are session-only; closing CodeReview discards in-memory notes unless you export the review
- Note anchors are based on new-file line numbers

## Acknowledgements

This plugin was inspired by the talk _"Programar en 2026: the human-in-the-loop"_ at [JSConf ES](https://www.jsconf.es) by Javi Velasco [@javivelasco](https://github.com/javivelasco).
