# Task Completion Checklist

After completing any code change:

1. **Lint**: `make lint` — run luacheck, fix any warnings
2. **Test**: `make test` — run the full test suite (requires `make deps` first if .deps/ is missing)
3. **Manual check**: If modifying UI or diff behavior, test interactively in Neovim

## Notes
- Tests are in `tests/codereview/` as `*_spec.lua` busted files
- Add or update the corresponding `_spec.lua` when adding new functionality
- Tests run sequentially (plenary sequential=true)
