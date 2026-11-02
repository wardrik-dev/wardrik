# Writing the docs

For the site, package guides, READMEs and docs in the code. Model: Phoenix, Ecto, Req and Oban
hexdocs, and Stripe for HTTP routes.

- Code first. An example shows usage. Prose only adds what the code can't show.
- If code can't show how to use something, the API is wrong. Fix or report the API.
- Concise bullets over paragraphs. Short pages.
- Plain, concrete words. Name what the reader types or sees.
- Sentences under about 20 words. No colon-chains or stacked clauses.
- No internal jargon in guides: no "seam", "host", "principal", "actor", "on whose behalf".
  Say "your app". Reference may name the types and fields.
- Say "Wardrik", never "a Wardrik".
- The demo module is `MyApp.AgentRuntime`.
- Install lines name the release: `{:wardrik, "~> 0.1.0-rc.2"}`.
- Options come from the NimbleOptions schema, as a `## Options` list. Don't retype them.
- Link to the reference instead of repeating it. A fact lives in one place.
- A moduledoc is a summary sentence, an example, then what a caller must know.
- Guides run as written in a fresh IEx session or shell.
- No history, no rationale essays, no marketing adjectives.
