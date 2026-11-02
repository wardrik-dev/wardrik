defmodule WardrikDaemon.Authorizer do
  @moduledoc """
  The daemon's `Wardrik.Authorizer`. It decides with `config.yaml`'s `roles` and `bindings`, as
  Kubernetes RBAC does. See `WardrikDaemon.Config.Access`.

      Wardrik.start_link(
        name: MyAgents,
        authorizer: {WardrikDaemon.Authorizer, %{access: config.access, store: store}}
      )

    * A token's user is `user:ID`, plus `group:NAME` for each of its groups.
    * An agent calling tools is `agent:NAME`. It gets its own bindings, never its owner's.
    * Everyone may do anything to what they own: their agents, secrets, servers, webhooks and
      OAuth apps. See `WardrikDaemon.Owners`.
    * Everyone manages their own connections.
    * Making an agent is `create` on `agent`. A rule with `names` doesn't allow it.
    * A chat member acts as the user `WardrikDaemon.ChannelMembers` maps them to. They may only
      `ask`, `read`, `events` and decide, on the agents of the workspace's owner. Whoever asked
      for a turn may always decide its calls.
    * Tokens are in no org: only a binding in `"*"` on `token` reaches them. Only the admin makes
      a token for `user:admin`.
    * An agent the daemon has no record of is not found. See `WardrikDaemon.AgentRecords`.

  Returns `{:error, :not_found}` where no binding reaches the resource's org, and
  `{:error, :forbidden}` where one does but no rule allows the verb.
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Authorizer.Request
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Owners

  @admin Access.admin()
  @member ~w(ask read events)
  @deciding ~w(decide approve deny)

  @typedoc "The roles and bindings `config.yaml` declares, and where agents' records are kept."
  @type opts() :: %{access: Access.t(), store: WardrikStore.t()}

  @impl Wardrik.Authorizer
  @spec authorize(Request.t(), opts()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Request{resource: {:agent, id}} = request, opts) do
    case AgentRecords.fetch(opts.store, id) do
      {:ok, record} -> decided(request, Map.put(opts, :record, record))
      :error -> {:error, :not_found}
    end
  end

  def authorize(%Request{} = request, opts), do: decided(request, Map.put(opts, :record, nil))

  defp decided(%Request{actor: {:channel, _name}} = request, opts), do: member(request, opts)

  # A token for the admin is the admin's alone to make, whatever else may make tokens, as
  # Kubernetes' TokenRequest needs rights on the very account.
  defp decided(
         %Request{action: "token.create", resource: {:token, "user:" <> id}} = request,
         opts
       )
       when id == @admin do
    case request do
      %Request{actor: nil, principal: %{id: @admin}} -> bound(request, opts)
      _anyone_else -> {:error, :forbidden}
    end
  end

  defp decided(%Request{} = request, opts),
    do: if(owns?(request, opts), do: :ok, else: bound(request, opts))

  defp owns?(%Request{actor: nil, principal: %{id: id}, resource: {:agent, _id}}, opts),
    do: opts.record.owner == id

  defp owns?(%Request{actor: nil, principal: %{id: id}, resource: {:connection, id}}, _opts),
    do: true

  # The deployment's own is in no org, so no one owns it.
  defp owns?(%Request{actor: nil, principal: %{id: id}, resource: {kind, id} = resource}, opts)
       when kind in [:secret, :mcp_server, :notify_target, :provider, :agents],
       do: Owners.org_of(opts.store, resource) != nil

  defp owns?(_request, _opts), do: false

  defp bound(request, %{access: %{roles: roles, bindings: bindings}} = opts) do
    org = Owners.org_of(opts.store, request.resource)

    reaching =
      for binding <- bindings,
          binding.org == "*" or binding.org == org,
          subjects = subjects(request, binding.org, opts),
          Enum.any?(binding.subjects, &(&1 in subjects)),
          do: Map.fetch!(roles, binding.role)

    cond do
      reaching == [] -> {:error, :not_found}
      Enum.any?(reaching, &allows?(&1, request, opts.record)) -> :ok
      true -> {:error, :forbidden}
    end
  end

  # An agent is bound by its name in the binding's org.
  defp subjects(%Request{actor: {:agent, id}}, org, opts) do
    case AgentRecords.fetch(opts.store, id) do
      {:ok, %{org: ^org, name: name}} -> ["agent:" <> name]
      _elsewhere -> []
    end
  end

  defp subjects(%Request{actor: nil, principal: principal}, _org, _opts),
    do: ["user:" <> principal.id | for(group <- groups(principal), do: "group:" <> group)]

  defp subjects(_request, _org, _opts), do: []

  defp groups(%{attributes: attributes}), do: Map.get(attributes, :groups, [])

  defp allows?(rules, %Request{action: action, resource: {kind, id}}, record) do
    Enum.any?(rules, fn rule ->
      matches?(rule.verbs, verb(action)) and matches?(rule.kinds, kind(kind)) and
        named?(rule.names, kind, record || id)
    end)
  end

  defp kind(:agents), do: "agent"
  defp kind(kind), do: Atom.to_string(kind)

  # Agents are named by their names; making one names none, as Kubernetes' create.
  defp named?(nil, _kind, _named), do: true
  defp named?(_names, :agents, _owner), do: false
  defp named?(names, :agent, record), do: record.name in names
  defp named?(names, _kind, id), do: id in names

  defp matches?(allowed, value), do: "*" in allowed or value in allowed

  defp verb(action), do: action |> String.split(".") |> List.last()

  defp member(
         %Request{resource: {:agent, _id}, context: %{installation: %{owner: within}}} = request,
         opts
       ) do
    if within == "*" or Owners.within?(opts.record.owner, within),
      do: member(verb(request.action), request, opts),
      else: {:error, :not_found}
  end

  defp member(_request, _opts), do: {:error, :not_found}

  defp member(verb, request, opts) when verb in @member, do: as_user(request, opts)

  defp member(verb, %Request{principal: principal, context: context} = request, opts)
       when verb in @deciding do
    if context[:asked_by] == principal.id, do: :ok, else: as_user(request, opts)
  end

  defp member(_verb, _request, _opts), do: {:error, :forbidden}

  # The member's user, deciding as they would themselves.
  defp as_user(request, opts) do
    user = %{request | actor: nil}
    if owns?(user, opts), do: :ok, else: bound(user, opts)
  end
end
