# Suggested Commands

## Development
```bash
make deps    # Clone plenary.nvim into .deps/ (run once before testing)
make test    # Run all tests headlessly via Neovim + plenary busted
make lint    # Run luacheck on lua/ directory
```

## Testing detail
```bash
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests { sequential = true, timeout = 10000 }" \
  -c "qa!"
```

## Linting detail
```bash
luacheck lua/ --globals vim
```

## Git utilities (Darwin/macOS)
```bash
git log --oneline -10
git diff
git status
```
