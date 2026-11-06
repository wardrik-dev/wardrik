defmodule WardrikDaemon.Capabilities do
  @moduledoc """
  The tools the daemon offers agents by name.

      tools: [run_lua, web_search, deep_research, agent_create]

    * `run_lua` - Lua in a sealed sandbox. See `WardrikLua`.
    * `web_search` - Brave search. Needs `brave.api_key`. See `WardrikBrave`.
    * `deep_research` - researches a topic with subagents. See `WardrikResearch`.
    * `agent_create` - makes a worker in the agent's org. See `WardrikDaemon.CreateAgent`.

  `config.yaml`'s `harnesses` add a tool each, by name. See `WardrikDaemon.Harnesses`.
  """

  @doc "Returns the tools by name, as Wardrik's `:capabilities` option takes them."
  @spec all(atom(), WardrikStore.t()) :: keyword()
  def all(wardrik, store),
    do: [
      run_lua: WardrikLua,
      web_search: {WardrikBrave, brave: brave(wardrik)},
      deep_research: WardrikResearch,
      agent_create: {WardrikDaemon.CreateAgent, wardrik: wardrik, store: store}
    ]

  @doc "Returns the name `WardrikBrave` runs under for `wardrik`, as `MyWardrik.Brave`."
  @spec brave(atom()) :: atom()
  def brave(wardrik), do: Module.concat(wardrik, Brave)
end
