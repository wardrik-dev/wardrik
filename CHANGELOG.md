# Changelog

## 0.1.0-rc.2

### Breaking

- `WardrikWorkspace.Files.read/2`, `write/2` and `delete/2` take the store, then named
  `:tree`, `:path`, `:file` and `:version`, so a tree and a path can't swap.

## 0.1.0-rc.1 (2026-10-30)

- Six file tools over trees kept in a `WardrikStore`: read, write, edit, list, search and delete.
- Each file versioned, so a stale write is refused.
- Trees shared under `shared/<name>/`, to read and write or only to read.
- `WardrikWorkspace.Context`, a middleware that reads named files into each turn within a budget.
- Each call names what it acts on, for policy rules like `write_file(notes/*)`.
