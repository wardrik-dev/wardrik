# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The primary user is a developer adopting Wardrik from outside Elixir: they
install the daemon, write agents as Markdown files, and drive them from their
own app through the HTTP API and the TypeScript SDK, offering tools that run in
their own process. They meet Wardrik first on the docs site and in a terminal,
deciding whether it is safe to put agents near real systems and then getting a
first agent running.

Other audiences, served after the developer:

- Operators and dev teams running the daemon: approving parked calls, watching
  agents, spending, the fleet across nodes, through the `wardrik` command, the
  TUI and the HTTP API.
- Elixir teams embedding Wardrik in their own application as a library.
- Small businesses whose agents live in Slack: their staff talk to an agent in a
  channel and approve its calls there; they never see the CLI or the docs.

## Product Purpose

Wardrik is an agent runtime built on OTP. Each agent is a process that holds its
own conversation, takes one turn at a time, and publishes everything it does to
one event stream. It runs as a daemon with agents written as Markdown files, or
inside an Elixir application as a library.

Success is a developer trusting agents with tools that act on real systems:
agents that keep going when a node is lost, and calls that a person can read the
rules for, and approve, before they happen.

## Positioning

Durable and governed. Agents are OTP processes that carry on through a node
being killed mid-turn, on another node, without running a tool call twice; and
every tool call passes a policy you can read, which allows it, asks a person, or
denies it. A framework that runs agents as functions in a request loop cannot
make the first claim, and one that leaves tools ungoverned cannot make the
second.

## Operating Context

- Install through a shell script on Linux or the Docker image, then
  `wardrik init`; agents are files in `~/.config/wardrik/agents/`, policies and
  `config.yaml` beside them.
- People reach agents in the terminal (`wardrik ask`, `watch`, `parked`,
  `approve`), in the TUI over SSH, over HTTP with server-sent events, and in
  Slack threads with Approve and Deny buttons.
- Developers offer tools from their own Node process as tool workers over a
  socket; each call carries an idempotency key.
- The docs site (Astro with Starlight, `docs/`) is the main web surface: install,
  quickstart, channels, recipes, concepts, guides, operating and reference
  pages, some of them generated from the code by `mix wardrik.docs`.
- The CLI and TUI are terminal surfaces outside this web platform; they share the
  product's vocabulary of agent states (running, waiting on a person, done,
  failed).

## Capabilities and Constraints

- Pre-release. Packages are versioned 0.1.0; nothing is published publicly yet.
- Core runs agents only and ships no tools; packages add tools (MCP servers,
  search, research, Lua, workspaces), stores (EKV on disk, Postgres, S3),
  credentials (vault, OAuth), policies, notices, triggers, workflows, channels
  (Slack first) and surfaces (HTTP, TUI, console, daemon).
- Terminology: an agent, its definition (agent file), a turn, a tool call, a
  policy that allows, asks or denies, a parked call waiting on a person, the
  fleet, a node, a cluster, a trigger, a tool worker, a token with a scope.
- No integration is canonical. Specific providers that happen to be built first
  are examples, never the product's identity.

## Brand Commitments

- Name: Wardrik. Marks in `docs/src/assets/mark-light.svg`,
  `docs/src/assets/mark-dark.svg` and `docs/public/favicon.svg`.
- Voice, as the shipped copy writes it: plain, concrete words; sentences that
  say what the system does ("A call that needs a person waits for one"); no hype,
  no jargon where an ordinary word serves, British spelling.
- The current visual tokens in `docs/src/styles/brand.css` (Ink, Signal and Amber
  on Paper, IBM Plex Sans and Mono, colour reserved for agent state) are
  provisional and may be replaced.

## Evidence on Hand

- Real copy: `README.md`, each package's README, and the docs content under
  `docs/src/content/docs/`.
- Real code to show: agent files, policies, and the TypeScript SDK examples in
  `sdks/typescript/examples/` (onboarding, refund, telegram).
- There are no public customers, testimonials, case studies, benchmarks,
  pricing or adoption numbers. Do not invent any; durability and governance
  claims point to the mechanism the docs describe.

## Product Principles

- Show the mechanism. Trust is earned by showing how a call is decided and how an
  agent survives a lost node, not by asserting it.
- A person stays in charge of what acts on the world: what waits on someone is
  always visible and answerable from where they already are.
- Plain over clever: every surface explains in its own words, without reference
  to other products or internal plans.
- Take only what you need: core stays small, and each surface presents its
  packages as choices rather than a bundle.
