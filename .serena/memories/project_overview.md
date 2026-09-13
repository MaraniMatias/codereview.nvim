# Project Overview: codereview.nvim

## Purpose
A Neovim plugin for inline code review on any `git diff`, right inside Neovim. Supports exporting reviews to markdown files.

## Key Features
- Two-panel layout (explorer + diff) with unified or side-by-side split view
- Inline notes on any diff line, with visual-selection support
- Markdown export (`:w` / `:W`) with two formats: `"default"` and a prompt-based flow
- Telescope picker for all notes
- File explorer with flat/tree layout toggle (`t`), badge + note counts
- Navigation: `]n`/`[n` (notes), `]f`/`[f` (files), `?` help window
- Inline word-level diff highlighting, gutter line numbers, sign column markers
- Unsaved-note protection, large diff pagination

## Repository
- GitHub: MaraniMatias/codereview.nvim
- Requires: Neovim >= 0.9
- License: See LICENSE
