# Changelog

## 0.1.0-rc.1 (unreleased)

- One tool per operation of an HTTP API, from its description.
- Reads Google Discovery documents. `WardrikRest.Reader` reads other formats.
- Credentials from `WardrikCore.Credentials` (a person's sign-in) or `WardrikCore.Keys`, sent only
  to the configured base URL. A refused token is refreshed once; a missing sign-in waits for it.
- `only`, `read_only` and `idempotent` by name or glob.
- Answers over `max_result_bytes` (128 KB unless set) are cut, with a note to ask for less.
