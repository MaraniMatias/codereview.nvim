# CodeReview.nvim

A Neovim plugin for Git diff-based code review. Navigate changed files, add inline notes on diffs, and export everything to a `review-YYYY-MM-DD.md`. It works both as `:CodeReview` inside Neovim and as `git difftool --dir-diff`.

The current implementation is centered on a two-panel unified diff workflow. `split` view is planned, but not implemented yet.

## Layout

```text
+---------------------+---------------------------------------+
|  FILES              |  DIFF (unified)                       |
|  > [M] src/foo.js   |  @@ -10,4 +10,6 @@                   |
|    > L42: revisit   |   context line                        |
|  > [A] src/bar.js   |  -old line                            |
|  > [D] src/baz.js   |  +new line  📝 revisit                |
+---------------------+---------------------------------------+
```

- Left panel: file explorer with badges, note counts, and note entries
- Right panel: unified diff view with highlights and virtual text notes

## Features

- Two-panel review layout in a dedicated tab
- Unified diff rendering with highlights
- Smart note action for create or edit on the current line
- Visual selection notes with captured code context
- Virtual text notes with a visibility toggle
- Explorer note entries and per-file note counts
- Telescope picker for all notes
- Markdown export with prompt flow and direct `:W` save
- Unsaved-note protection on close
- `git difftool --dir-diff` integration

## Requirements

- Neovim >= 0.9
- `telescope.nvim` optional, for the notes picker
- `nvim-web-devicons` optional, for file type icons in the explorer

## Installation

```lua
{
  "MaraniMatias/codereview.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("codereview").setup({})
  end,
}
```

## Configuration

```lua
require("codereview").setup({
  diff_view = "unified", -- "split" is planned, not implemented yet
  explorer_width = 30,
  max_diff_lines = 1200, -- initial visible diff lines before truncation
  diff_page_size = 400,  -- extra lines revealed per load-more action

  keymaps = {
    note = "n",                    -- smart add/edit note on current line
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
    load_more_diff = "L",         -- reveal more lines when a diff is truncated
  },

  review = {
    default_filename = "review-%Y-%m-%d.md",
    path = nil, -- nil = git root
  },
})
```

Default keymap contract: `<Tab>` cycles focus between explorer and diff, and `za` expands or collapses note groups in the explorer. Both can be remapped in `keymaps`.

Large diffs keep the current behavior when they fit within `max_diff_lines`. When a diff exceeds that limit, CodeReview renders the first slice, shows a truncation sentinel at the bottom, and each `load_more_diff` action reveals another `diff_page_size` lines.

## Usage

### Inside Neovim

`CodeReview` accepts any arguments you would pass to `git diff`.

```vim
:CodeReview
:CodeReview main..feature
:CodeReview HEAD~3
:CodeReview --staged
:CodeReview -- path/to/file
:CodeReview --staged -- path/to/file
```

### As git difftool

Add this to `~/.gitconfig`:

```ini
[difftool "codereview"]
    cmd = nvim -c "lua require('codereview').difftool('$LOCAL', '$REMOTE')"
[difftool]
    prompt = false
```

Or use the wrapper shipped in `bin/codereview`:

```ini
[difftool "codereview"]
    cmd = /path/to/codereview/bin/codereview "$LOCAL" "$REMOTE"
```

The wrapper automatically captures `$MERGED` from git's environment to build a stable, repo-relative file identity — preventing note collisions when multiple files share the same basename (e.g. `src/utils/helpers.js` vs `src/components/helpers.js`).

Examples:

```bash
git difftool --dir-diff -t codereview
git difftool --dir-diff --cached -t codereview
git difftool --dir-diff -t codereview main..feature-branch
```

`--dir-diff` is the mode that gives the plugin all changed files at once, which is what enables the multi-file explorer.

## Saving and Closing

- `<C-s>` opens the save prompt and writes the markdown review
- `:w` inside the CodeReview buffers triggers the same prompt flow
- `:W` saves directly to the auto-generated filename
- notes live in memory for the current Neovim session only; exporting saves the Markdown review, not the in-editor note state
- `:q` warns if you have unsaved notes
- `:q!` forces the review tab to close

## Keybindings

### Explorer Panel

| Key             | Action                                                    |
| --------------- | --------------------------------------------------------- |
| `j` / `k`       | Navigate files and note entries; preview updates on pause |
| `Enter` / `l`   | Focus the diff panel for the selected item                |
| `Enter` on note | Focus that note in the diff                               |
| `za`            | Expand or collapse notes for the selected file            |
| `]f` / `[f`     | Next or previous file                                     |
| `R`             | Refresh file list                                         |
| `<Tab>`         | Focus diff panel                                          |
| `q`             | Close review                                              |
| `<C-s>`         | Save review                                               |

You can remap either `cycle_focus` or `toggle_notes` in your config.

### Diff Panel

| Key          | Action                                 |
| ------------ | -------------------------------------- |
| Vim motions  | Normal navigation                      |
| `n`          | Smart add or edit note on current line |
| `V` then `n` | Add note from visual selection         |
| `]n` / `[n`  | Next or previous note in current file  |
| `]f` / `[f`  | Next or previous file                  |
| `L`          | Load more lines for a truncated diff   |
| `<leader>uh` | Toggle virtual text notes              |
| `<Space>n`   | Open Telescope notes picker            |
| `<Tab>`      | Focus explorer panel                   |
| `<C-s>`      | Save review                            |
| `q`          | Close review                           |

### Note Float

| Key         | Action                                                 |
| ----------- | ------------------------------------------------------ |
| Insert mode | Write note text                                        |
| `<C-s>`     | Confirm and save                                       |
| `q`         | Cancel in normal mode                                  |
| `<Esc>`     | Return to normal mode, then cancel with `q` or `<Esc>` |

## `review.md` Format

````markdown
# Code Review — 2026-03-14

## Summary

_Write your summary here._

---

## `src/foo.js`

### Line 42

```javascript
const result = a + b;
```

> revisit this calculation

---

### Lines 67-72

```javascript
function handleUser(user) {
  if (user.name) {
    return user.name;
  }
}
```

> add a null check for `user` before accessing `.name`

---

_Generated by CodeReview_
````

## Current Limitations

- `diff_view = "split"` is not implemented yet
- `:CodeReview` passes all arguments directly to `git diff`
- notes are session-only; closing CodeReview discards in-memory notes unless you export the review
- note anchors are based on new-file line numbers today
- `git difftool --dir-diff` status detection is still best-effort in edge cases

## Acknowledgements

This plugin was inspired by the talk _"Programar en 2026: the human-in-the-loop"_ at [JSConf ES](https://www.jsconf.es) by Javi Velasco [https://github.com/javivelasco](@javivelasco).
