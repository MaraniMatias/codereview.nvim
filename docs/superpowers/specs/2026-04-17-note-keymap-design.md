# Note Keymap Design

## Goal

Stop using `n` as the default key to add or edit notes so normal Vim search navigation with `n` works again inside CodeReview buffers.

## Current State

- `keymaps.note` defaults to `n`.
- The diff panel uses `n` for smart add or edit note on the current line.
- Visual mode also uses the same key to create a note from a selection.
- The explorer binds the same configured key for editing the current note.
- The notes picker already uses `<Space>n` by default, so moving note creation to `<leader>n` would conflict for users with `mapleader = " "`.

## Decision

Change the default note key from `n` to `a`.

## Why `a`

- It is short and easy to remember as "add note".
- It frees `n` so Vim's next-search-match behavior works again in review buffers.
- It avoids the default collision that `<leader>n` would create with the notes picker in common LazyVim-style setups.
- It keeps the change minimal because only the note action default changes; surrounding navigation keys can stay as they are.

## Scope

Update only the default keybinding and the places that document or test that default:

- `lua/codereview/config.lua`
- help text shown in the UI
- `README.md`
- tests that assert the current default key

## Non-Goals

- Changing `]n` or `[n` note navigation.
- Changing the notes picker key.
- Changing the user-facing remapping API.

## Behavior After Change

- Normal mode `a` adds or edits a note on the current diff line.
- Visual mode `a` creates a note from the selected diff range.
- Explorer mode `a` edits the current note item.
- Normal Vim `n` remains available for search result navigation.
- Users can still override `keymaps.note` in `setup()`.

## Error Handling And Compatibility

- No migration is needed because keymaps are configured at runtime.
- Existing users who already override `keymaps.note` keep their explicit configuration.
- Users relying on the old default `n` can restore it manually via config.

## Testing

- Update config tests that check the default or overridden note key.
- Update keymap-related tests in diff and explorer flows if they assert `n`.
- Sanity-check that documentation and in-app help show `a` instead of `n` for note creation.
