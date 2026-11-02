# Changelog

## 0.1.0-rc.2 (2026-11-02)

- Requires `wardrik_core` 0.1.0-rc.2.

## 0.1.0-rc.1 (2026-10-30)

- `run_lua`, a tool that runs the Lua 5.3 an agent writes, in a sealed sandbox.
- The VM is `lua`, written in Elixir. It can't reach anything outside itself.
- `string`, `table`, `math`, `utf8` and the parts of `os` that touch nothing outside. `io`,
  `os.execute`, `require`, `load` and the like raise when called.
- Each run in a task of its own, under a deadline, a memory budget, a step budget and a call
  depth. `:limits` changes them.
- Offered by name in Wardrik, and by the daemon as `run_lua`.
