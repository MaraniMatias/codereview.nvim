# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [0.1.0] - 2024-01-01

### Added

- Two-panel unified diff layout: file explorer (left) + diff view (right)
- File explorer with status badges (`[M]`, `[A]`, `[D]`, `[R]`), note counts, and expandable note entries
- Unified diff view with syntax highlighting for added, deleted, and context lines
- Inline notes: add/edit notes on any diff line; notes persist to a Markdown file
- Virtual text: notes displayed as inline virtual text in the diff view with toggle support
- Large diff truncation: initial slice controlled by `max_diff_lines`; `load_more_diff` reveals `diff_page_size` more lines incrementally
- Telescope integration: optional notes picker (`<Space>n`) for searching and jumping to notes
- `nvim-web-devicons` integration: optional file-type icons in the explorer
- `:CodeReview [args]` command — open a review for the working tree or any `git diff` ref
- `:CodeReviewDifftool` command — open as `git difftool --dir-diff` with `$LOCAL`/`$REMOTE`/`$MERGED` support
- `:CodeReviewRefresh` — re-scan changed files without closing the layout
- Configurable keymaps, explorer width, note truncation lengths, and review output path/filename
- Export notes to `review-YYYY-MM-DD.md` (configurable filename and path)
