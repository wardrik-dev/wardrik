# Writing the docs

Help developers understand Wardrik, run it, and build with it.

- Lead with what the reader can accomplish, then explain how.
- Use familiar technical terms and natural sentences. Keep the context needed to understand them.
- Show runnable examples with prerequisites and expected results. Label partial examples and illustrative output.
- Explain concepts when readers first need them. Use consistent names for the same thing.
- Remove repetition. Link to reference pages for complete settings, fields, and edge cases.
- State guarantees and limitations precisely, especially for approvals, budgets, security, and recovery.
- Choose paragraphs, lists, and tables to suit the information. Optimize for understanding, not a word count.
- Keep installation commands, release versions, and examples consistent.

The site covers the daemon, CLI, configuration, agent files, HTTP API, and TypeScript SDK.
Document Elixir embedding in HexDocs and package READMEs.

For Elixir packages, use `MyApp.AgentRuntime` in examples, generate option documentation from
NimbleOptions schemas, and verify guides in a fresh IEx session.
