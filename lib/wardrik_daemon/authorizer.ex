defmodule WardrikDaemon.Authorizer do
  @moduledoc """
  Decides what each scope may do. It's the daemon's `Wardrik.Authorizer`, deciding as Kubernetes
  RBAC and Cedar do, with the roles and bindings `config.yaml` declares. See
  `WardrikDaemon.Config.Access`.

    * An agent acting through its tools is `agent:ID`, and nothing else. It gets its own
      bindings, never its owner's, as a Kubernetes ServiceAccount does.
    * Anyone else is `user:ID`, and `group:NAME` for each of the principal's `:groups`
      attributes.
    * A principal acting itself may do anything to the agents it owns, to what it holds as
      their owner, and to its secrets, MCP servers and notify targets: `resource.owner ==
      principal`, in Cedar's words. See `WardrikDaemon.Owners`.
    * A chat member, through a channel, may `ask`, `read` and `events` the agents within the
      installation's owner, and `decide` only the calls they asked for or, as an approver, any.
      Nothing else.
    * Otherwise, a binding in the resource's org, or in `"*"`, gives one of them a role with a
      rule that matches the action's verb and the resource.

  Tokens are in no org, so only a binding in `"*"` with a rule on the `token` kind reaches them.
  The owner rule never does. A token for `user:admin` is the admin's alone to make, whatever
  bindings say, as Kubernetes' TokenRequest needs rights on the very account it's for.

  Returns `{:error, :not_found}` where none of their bindings reaches the resource's org, so they
  learn nothing about it, and `{:error, :forbidden}` where one does but no rule allows the verb.

      {:ok, config} = WardrikDaemon.Config.read(dirs, env)
      Wardrik.start_link(name: MyAgents, authorizer: {WardrikDaemon.Authorizer, config.access})
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Authorizer.Request
  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Owners

  @admin Access.admin()
  @member ~w(ask read events)
  @deciding ~w(decide approve deny)

  @impl Wardrik.Authorizer
  @spec authorize(Request.t(), Access.t()) :: :ok | {:error, :forbidden | :not_found}
  def authorize(%Request{actor: {:channel, _name}} = request, _access), do: member(request)

  # A token for the admin is the admin's alone to make, whatever else may make tokens, as
  # Kubernetes' TokenRequest needs rights on the very account.
  def authorize(
        %Request{action: "token.create", resource: {:token, "user:" <> id}} = request,
        access
      )
      when id == @admin do
    case request do
      %Request{actor: nil, principal: %{id: @admin}} -> bound(request, access)
      _anyone_else -> {:error, :forbidden}
    end
  end

  def authorize(%Request{} = request, access),
    do: if(owns?(request), do: :ok, else: bound(request, access))

  defp owns?(%Request{actor: nil, principal: %{id: id}, resource: {:agent, agent}}),
    do: Owners.owner(agent) == {:ok, id}

  # The deployment's own is in no org, so no one owns it.
  defp owns?(%Request{actor: nil, principal: %{id: id}, resource: {kind, id} = resource})
       when kind in [:owner, :secret, :mcp_server, :notify_target],
       do: Owners.org_of(resource) != nil

  defp owns?(_request), do: false

  defp bound(request, %{roles: roles, bindings: bindings}) do
    subjects = subjects(request)
    org = Owners.org_of(request.resource)

    reaching =
      for binding <- bindings,
          binding.org == "*" or binding.org == org,
          Enum.any?(binding.subjects, &(&1 in subjects)),
          do: Map.fetch!(roles, binding.role)

    cond do
      reaching == [] -> {:error, :not_found}
      Enum.any?(reaching, &allows?(&1, request)) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp subjects(%Request{actor: {:agent, id}}), do: ["agent:" <> id]

  defp subjects(%Request{actor: nil, principal: principal}),
    do: ["user:" <> principal.id | for(group <- groups(principal), do: "group:" <> group)]

  defp subjects(_request), do: []

  defp groups(%{attributes: attributes}), do: Map.get(attributes, :groups, [])

  defp allows?(rules, %Request{action: action, resource: {kind, name}}) do
    Enum.any?(rules, fn rule ->
      matches?(rule.verbs, verb(action)) and matches?(rule.kinds, Atom.to_string(kind)) and
        (rule.names == nil or name in rule.names)
    end)
  end

  defp matches?(allowed, value), do: "*" in allowed or value in allowed

  defp verb(action), do: action |> String.split(".") |> List.last()

  defp member(
         %Request{resource: {:agent, id}, context: %{installation: %{owner: within}}} = request
       ) do
    case Owners.owner(id) do
      {:ok, owner} ->
        if Owners.within?(owner, within),
          do: member(verb(request.action), request),
          else: {:error, :not_found}

      :error ->
        {:error, :not_found}
    end
  end

  defp member(_request), do: {:error, :not_found}

  defp member(verb, _request) when verb in @member, do: :ok

  defp member(verb, %Request{principal: principal, context: context}) when verb in @deciding do
    if context[:approver] == true or context[:asked_by] == principal.id,
      do: :ok,
      else: {:error, :forbidden}
  end

  defp member(_verb, _request), do: {:error, :forbidden}
end
