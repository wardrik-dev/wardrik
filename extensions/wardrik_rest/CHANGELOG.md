# Changelog

## 0.1.0-rc.1 (2026-11-13)

- One tool per operation of an HTTP API, from its description.
- Reads OpenAPI 3.0 and 3.1, in JSON or YAML, as `{WardrikRest.OpenAPI, url: url}`, `path:` or
  `document:`, with JSON and form-encoded bodies. Reads Google Discovery documents as
  `{WardrikRest.Discovery, url: url}` or `document:`. Other formats are a module with the
  `WardrikRest.Reader` behaviour.
- Credentials from `WardrikCore.Credentials` (a person's sign-in) or `WardrikCore.Keys`, sent only
  to the configured base URL. A refused token is refreshed once; a missing sign-in waits for it.
- `only`, `read_only` and `idempotent` by name or glob. A glob leaves out operations whose tool
  names would be over 64 characters.
- `schemes`: schemes a description doesn't name, sent on every operation before its own.
- Answers over `max_result_bytes` (128 KB unless set) are cut, with a note to ask for less.
- `WardrikRest.API.schema/0`, to check options before loading.
- A tool's schema is fitted into `max_schema_bytes` (16 KB unless set): types deeper than fit are
  named instead, by type or by their path from the tool, and `<api>__describe` gives their
  fields. Where even that is too long, arguments keep their descriptions' first sentence. Specs keep their schemas as named
  `types`; Google's long type names are shortened, and its `UNSPECIFIED` and `UNKNOWN` enum
  values left out.
- `argument_headers`: headers each tool takes as optional arguments, such as Google Ads'
  `login-customer-id`.
