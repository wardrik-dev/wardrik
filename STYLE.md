# Writing the docs

For the site, package guides, READMEs and docs in the code. Model: Phoenix, Ecto, Req and Oban
hexdocs, and Stripe for HTTP routes.

The site documents the daemon: the `wardrik` command, `config.yaml`, agent files, the HTTP API and
the TypeScript SDK. Embedding Wardrik in an Elixir app is documented in hexdocs and the package
READMEs, never on the site.

- Code first. An example shows usage. Prose only adds what the code can't show.
- If code can't show how to use something, the API is wrong. Fix or report the API.
- Concise bullets over paragraphs. Short pages.
- Plain, concrete words. Name what the reader types or sees.
- Literal programming terms over metaphor. "Pass `--conversation ID`", "takes an `org` argument",
  "returns", "receives", "has many", "calls", "is set to", "defines". Not "hold", "takes the
  messages", "hands it", "lands", "lives", "says which", "reaches", "waits for a person".
- No personal or physical phrasing for software: not "hand it work", "give it", "hear back",
  "wakes", "asks your app". Say "send", "set", "pass", "receives", "starts", "calls".
- Describe software as a system, not a person. "An agent is composed of", "manages", "processes",
  "is configured with". Not "an agent has a conversation", "it thinks", "it knows", "it wants".
- Sentences under about 20 words. No colon-chains or stacked clauses.
- One fact per sentence, in the order things happen. Name the subject first. No fragments
  ("Tell it one."), no trailing appositives ("…, the agent you ask for outcomes").
- Don't narrate what a code block shows ("It asks for X. Then:"). Show the block, or name it in
  a few words.
- No internal jargon in guides: no "seam", "host", "principal", "actor", "on whose behalf".
  Say "your app". Reference may name the types and fields.
- Say "Wardrik", never "a Wardrik".
- Link to the reference instead of repeating it. A fact lives in one place.
- Guides run as written in a fresh shell.
- No history, no rationale essays, no marketing adjectives.
- No conversational voice: no "let's", "we", "notice", "reach for", "to recap". State facts.
- Use the fewest words that stay clear. Prefer a list or table to a paragraph.

## Elixir packages (hexdocs and READMEs only)

- The demo module is `MyApp.AgentRuntime`.
- Install lines name the release: `{:wardrik, "~> 0.1.0-rc.4"}`.
- Options come from the NimbleOptions schema, as a `## Options` list. Don't retype them.
- A moduledoc is a summary sentence, an example, then what a caller must know.
- Guides run as written in a fresh IEx session.
