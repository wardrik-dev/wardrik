defmodule Wardrik.Children do
  @moduledoc """
  The processes Wardrik supervises, in start order:

    1. The store, unless it's already running.
    2. The vault, with `:keys`.
    3. Sign-ins, with `:oauth`.
    4. MCP servers.
    5. Events.
    6. Tool workers.
    7. Agents.
    8. Triggers.
    9. The sleeper. See `Wardrik.Sleeper`.
    10. Channels.
    11. Listeners.
    12. Notices. See `Wardrik.Notify`.
    13. Delegation. See `Wardrik.Delegation`. It's last, so restarting it restarts nothing else.
  """

  @doc "Returns Wardrik's children, in start order."
  @spec children(Wardrik.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(wardrik),
    do:
      [{WardrikStore, wardrik.store}] ++
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

  defp mcp(wardrik), do: [mcp_spec(wardrik)]

  # The deployment's servers read the deployment's secrets, each owner's server its owner's.
  @doc false
  def mcp_spec(wardrik) do
    servers =
      for {name, opts} <- wardrik.mcp || [],
          do: {name, opts |> Keyword.delete(:orgs) |> Keyword.put(:owner, "deployment")}

    WardrikMCP.child_spec(
      name: Wardrik.mcp(wardrik),
      servers: servers,
      store: wardrik.store,
      check: wardrik.egress,
      secret: &Wardrik.Sealed.fetch(wardrik, &1, &2)
    )
  end

  @doc false
  def start_built({module, function, args}) do
    %{start: {start_module, start_function, start_args}} = apply(module, function, args)
    apply(start_module, start_function, start_args)
  end

  defp started(spec, build), do: %{spec | start: {__MODULE__, :start_built, [build]}}

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
      opts
      |> Keyword.merge(
        server: Wardrik,
        wardrik: wardrik.name,
        channel: name,
        store: wardrik.store
      )
      |> module.child_spec()
      |> Supervisor.child_spec(id: {Wardrik.Channel, name})
      |> started({__MODULE__, :channel_spec, [wardrik, name, module, opts]})
    end
  end

  @doc false
  def channel_spec(wardrik, name, module, opts),
    do: module.child_spec(Wardrik.Operations.Channels.options(wardrik, name, opts))

  defp listeners(wardrik), do: Enum.map(wardrik.listeners, &listener(&1, wardrik.name))

  defp listener({module, opts}, name), do: {module, Keyword.put(opts, :wardrik, name)}
  defp listener(module, name), do: {module, wardrik: name}

  defp agents(wardrik), do: {WardrikCore, name: Wardrik.agents(wardrik), backend: wardrik.backend}
end
