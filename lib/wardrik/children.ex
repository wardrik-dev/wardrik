defmodule Wardrik.Children do
  @moduledoc """
  What a Wardrik runs, in the order it starts them: its store, unless you run it, its vault and
  sign-ins, when it keeps credentials, the MCP servers its agents reach, then its agents' events,
  the workers that offer them tools, its agents, their triggers, what puts them to sleep, its
  channels, the listeners it's given, what sends notices, and what brings delegated answers back,
  last, so restarting it restarts nothing else.
  """

  @doc "Returns the children `wardrik` runs, in order."
  @spec children(Wardrik.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(wardrik),
    do:
      store(wardrik) ++
        vault(wardrik) ++
        oauth(wardrik) ++
        mcp(wardrik) ++
        [
          events(wardrik),
          workers(wardrik),
          agents(wardrik),
          triggers(wardrik),
          {Wardrik.Sleeper, wardrik}
        ] ++
        channels(wardrik) ++
        listeners(wardrik) ++
        Wardrik.Notify.Server.children(wardrik) ++
        [{Wardrik.Delegation, wardrik}]

  defp store(%Wardrik{own_store: true, store: store}), do: [{WardrikStore, store}]
  defp store(_wardrik), do: []

  defp vault(%Wardrik{keys: []}), do: []

  defp vault(wardrik) do
    [
      {WardrikVault,
       name: Wardrik.vault(wardrik),
       store: wardrik.store,
       keys: wardrik.keys,
       grants: grants(wardrik)}
    ]
  end

  defp grants(%Wardrik{oauth: nil}), do: nil
  defp grants(wardrik), do: {WardrikOAuth, Wardrik.oauth(wardrik)}

  defp oauth(%Wardrik{oauth: nil}), do: []

  defp oauth(wardrik) do
    options = [
      name: Wardrik.oauth(wardrik),
      vault: Wardrik.vault(wardrik),
      store: wardrik.store,
      on_granted: {Wardrik.SignIns, :granted, [Wardrik.agents(wardrik)]},
      check: wardrik.egress
    ]

    [{WardrikOAuth, options ++ wardrik.oauth}]
  end

  defp mcp(wardrik),
    do: [
      {WardrikMCP,
       name: Wardrik.mcp(wardrik),
       servers: wardrik.mcp || [],
       store: wardrik.store,
       check: wardrik.egress}
    ]

  defp events(wardrik) do
    {WardrikEvents,
     name: Wardrik.events(wardrik),
     store: wardrik.store,
     deployment: wardrik.deployment,
     retention: wardrik.retention}
  end

  defp triggers(wardrik) do
    {WardrikTriggers,
     [
       name: Wardrik.triggers(wardrik),
       store: wardrik.store,
       target: {Wardrik.TriggerTarget, wardrik}
     ] ++
       wardrik.triggers}
  end

  defp workers(wardrik), do: {Group, name: Wardrik.Workers.group(wardrik), log: false}

  defp channels(wardrik) do
    for {name, {module, opts}} <- wardrik.channels do
      opts = Wardrik.Operations.Channels.options(wardrik, name, opts)
      Supervisor.child_spec(module.child_spec(opts), id: {Wardrik.Channel, name})
    end
  end

  defp listeners(wardrik), do: Enum.map(wardrik.listeners, &listener(&1, wardrik.name))

  defp listener({module, opts}, name), do: {module, Keyword.put(opts, :wardrik, name)}
  defp listener(module, name), do: {module, wardrik: name}

  defp agents(wardrik), do: {WardrikCore, name: Wardrik.agents(wardrik), backend: wardrik.backend}
end
