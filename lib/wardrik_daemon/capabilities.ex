defmodule WardrikDaemon.Capabilities do
  @moduledoc """
  The tools the daemon offers agents by name.

      tools: [run_lua, web_search, deep_research, agent_create, settings, help]

    * `run_lua` - Lua in a sealed sandbox. See `WardrikLua`.
    * `web_search` - Brave search. Needs `brave.api_key`. See `WardrikBrave`.
    * `deep_research` - researches a topic with subagents. See `WardrikResearch`.
    * `agent_create` - makes a worker in the agent's org. See `WardrikDaemon.CreateAgent`.
    * `settings` - reads and adds MCP servers, notify targets and OAuth apps, and asks a person to
      seal secrets. See `WardrikDaemon.SettingsTools`.
    * `help` - answers from the documentation and this deployment's files, and runs the doctor's
      checks. See `WardrikDaemon.HelpTools`.

  `config.yaml`'s `harnesses` add a tool each, by name. See `WardrikDaemon.Harnesses`.
  """

  @doc """
  Returns the tools by name, as Wardrik's `:capabilities` option takes them. `daemon` is the map
  the dashboard and HTTP API read: `:wardrik`, `:store`, `:orgs`, `:config`, `:dirs`, `:env` and
  `:web`.
  """
  @spec all(map()) :: keyword()
  def all(%{wardrik: wardrik, store: store} = daemon),
    do: [
      run_lua: WardrikLua,
      web_search: {WardrikBrave, brave: brave(wardrik)},
      deep_research: WardrikResearch,
      agent_create: {WardrikDaemon.CreateAgent, wardrik: wardrik, store: store},
      settings: {WardrikDaemon.SettingsTools, daemon: daemon},
      help: {WardrikDaemon.HelpTools, daemon: daemon}
    ]

  @doc "Says how to give `web_search` a key, for its description and its error while it has none."
  @spec brave_help() :: String.t()
  def brave_help,
    do:
      "To turn it on, a person seals a Brave Search API key with `wardrik vault put BRAVE_API_KEY --for api_key`, or sets BRAVE_API_KEY in the daemon's env file and restarts it. Keys are at https://brave.com/search/api/."

  @doc "Returns the name `WardrikBrave` runs under for `wardrik`, as `MyWardrik.Brave`."
  @spec brave(atom()) :: atom()
  def brave(wardrik), do: Module.concat(wardrik, Brave)
end
