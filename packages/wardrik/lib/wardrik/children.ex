defmodule Wardrik.Children do
  @moduledoc false

  @doc "Returns Wardrik's children, in start order."
  @spec children(Wardrik.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(wardrik),
    do:
      [{Wardrik.Store, wardrik.store}] ++
        vault(wardrik) ++
        oauth(wardrik) ++
        mcp(wardrik) ++
        [
          events(wardrik),
          {Wardrik.Notify.Server, wardrik},
          workers(wardrik),
          agents(wardrik),
          triggers(wardrik),
          {Wardrik.Sleeper, wardrik}
        ] ++
        channels(wardrik) ++
        listeners(wardrik) ++
        [{Wardrik.Delegation, wardrik}]

  defp vault(%Wardrik{vault_keys: []}), do: []

  defp vault(wardrik) do
    [
      {Wardrik.Vault,
       name: Wardrik.vault(wardrik),
       store: wardrik.store,
       keys: wardrik.vault_keys,
       grants: wardrik.grants}
    ]
  end

  defp oauth(%Wardrik{oauth: nil}), do: []

  defp oauth(wardrik) do
    options = [
      name: Wardrik.oauth(wardrik),
      vault: Wardrik.vault(wardrik),
      store: wardrik.store,
      on_granted: {Wardrik.SignIns, :granted, [Wardrik.agents(wardrik)]},
      check: wardrik.egress
    ]

    oauth =
      wardrik.oauth
      |> Keyword.delete(:providers)
      |> Keyword.put_new(:resolver, {Wardrik.OAuth.Apps, wardrik.name})

    [{Wardrik.OAuth, options ++ oauth}]
  end

  defp mcp(wardrik), do: [mcp_spec(wardrik)]

  # The deployment's servers read the deployment's secrets, each owner's server its owner's.
  @doc false
  @spec mcp_spec(Wardrik.t()) :: Supervisor.child_spec()
  def mcp_spec(wardrik) do
    servers =
      for {name, opts} <- wardrik.mcp,
          do: {name, Keyword.put(opts, :owner, "deployment")}

    Wardrik.MCP.child_spec(
      name: Wardrik.mcp(wardrik),
      servers: servers,
      store: wardrik.store,
      check: wardrik.egress,
      secret: &Wardrik.Vault.Lookup.fetch(wardrik, owner: &1, name: &2, kind: :header)
    )
  end

  @doc false
  @spec start_built({module(), atom(), [term()]}) :: Supervisor.on_start()
  def start_built({module, function, args}) do
    %{start: {start_module, start_function, start_args}} = apply(module, function, args)
    apply(start_module, start_function, start_args)
  end

  defp started(spec, build), do: %{spec | start: {__MODULE__, :start_built, [build]}}

  defp events(wardrik) do
    {Wardrik.EventLog,
     name: Wardrik.events(wardrik),
     store: wardrik.store,
     deployment: wardrik.deployment,
     retention: wardrik.retention,
     sinks: [
       {Wardrik.Notify.Sink, server: Wardrik.Notify.Server.name(wardrik.name)} | wardrik.sinks
     ]}
  end

  defp triggers(wardrik) do
    {Wardrik.Triggers,
     [
       name: Wardrik.triggers(wardrik),
       store: wardrik.store,
       target: {Wardrik.Triggers.Agents, wardrik}
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
  @spec channel_spec(Wardrik.t(), String.t(), module(), keyword()) :: Supervisor.child_spec()
  def channel_spec(wardrik, name, module, opts) do
    options = Wardrik.Operations.Channels.options(wardrik, name, opts)
    module.child_spec(options)
  end

  defp listeners(wardrik), do: Enum.map(wardrik.listeners, &listener(&1, wardrik.name))

  defp listener({module, opts}, name), do: {module, Keyword.put(opts, :wardrik, name)}
  defp listener(module, name), do: {module, wardrik: name}

  defp agents(wardrik) do
    {WardrikCore,
     [
       name: Wardrik.agents(wardrik),
       backend: wardrik.backend,
       configure: {Wardrik.Operations.Running, wardrik.name}
     ] ++ placement(wardrik.agents)}
  end

  defp placement(agents) do
    Enum.map(agents, fn
      {:max_per_node, limit} -> {:max_children, limit}
      {:hibernate_after, seconds} -> {:hibernate_after, :timer.seconds(seconds)}
      limit -> limit
    end)
  end
end
