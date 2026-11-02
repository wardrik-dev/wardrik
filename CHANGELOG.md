# Changelog

## 0.1.0-rc.2 (2026-11-02)

- Requires `wardrik_core` 0.1.0-rc.2.

## 0.1.0-rc.1 (2026-10-30)

- `web_search` through Brave's LLM Context API: the passages of each page that bear on the query,
  not a list of links.
- Freshness and exact date windows.
- `BRAVE_API_KEY` from the agent's `WardrikCore.Keys` first, then from the `:api_key` it was
  started with. An org can bring its own key.
- Keys held by a named process, never in an agent's saved state.
- Small results: 10 results and about 4,096 tokens, unless the agent asks for more.
- Offered by name in Wardrik, and by the daemon as `web_search`.
