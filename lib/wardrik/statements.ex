defmodule Wardrik.Statements do
  @moduledoc """
  The default `Wardrik.Authorizer`. Allows what the scope's `Wardrik.Statement`s allow.

      scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria", roles: [:reader], resources: ["acme/agent/*"])

  Anything no statement allows is refused.

  Statements cover resources by IAM-style name, which this reads from the agent's ID:

  | Resource | Named |
  | --- | --- |
  | `{:agent, "acme/@jon/triage"}` | `acme/@jon/agent/triage` |
  | `{:deployment, "local"}` | `deployment` |
  | `{:owner, "acme"}`, acting on the `mcp_server` `linear` | `acme/mcp_server/linear` |

  Statements, and the agent IDs they read, move to `WardrikDaemon`.
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Resource
  alias Wardrik.Scope
  alias Wardrik.Statement
  alias WardrikEvents.Pattern

  @impl Wardrik.Authorizer
  def authorize(
        _principal,
        action,
        resource,
        %{scope: %Scope{grants: statements}} = context,
        _config
      ) do
    case named(action, resource, context) do
      {:ok, name} -> decide(Enum.filter(statements, &reaches?(&1, name)), action)
      :error -> {:error, :not_found}
    end
  end

  defp named(_action, {:agent, id}, _context), do: Resource.agent(id)
  defp named(_action, {:deployment, _name}, _context), do: {:ok, Resource.deployment()}

  defp named(action, {:owner, owner}, context) do
    [kind, _verb] = String.split(action, ".", parts: 2)
    {:ok, Resource.owned(owner, kind, context[:name])}
  end

  defp decide([], _action), do: {:error, :not_found}

  defp decide(reaching, action),
    do: if(Enum.any?(reaching, &allows?(&1, action)), do: :ok, else: {:error, :forbidden})

  @impl Wardrik.Authorizer
  def holds?(_config, %Scope{grants: statements}, %Statement{
        actions: actions,
        resources: resources
      }) do
    pairs = for action <- actions, resource <- resources, do: {action, resource}
    Enum.all?(pairs, fn pair -> Enum.any?(statements, &holds_pair?(&1, pair)) end)
  end

  defp holds_pair?(%Statement{actions: actions, resources: resources}, {action, resource}),
    do: covers?(actions, action) and covers?(resources, resource)

  @doc """
  Returns whether `outer` covers every name the pattern `inner` covers.

      Wardrik.Statements.within?("acme/agent/*", "acme/*")
      #=> true

      Wardrik.Statements.within?("acme/a?", "acme/a*")
      #=> true

      Wardrik.Statements.within?("acme/a*", "acme/a?")
      #=> false
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(inner, outer), do: contained(outer, inner)

  defp covers?(patterns, inner), do: Enum.any?(patterns, &within?(inner, &1))

  defp contained("", ""), do: true
  defp contained("*" <> rest, ""), do: contained(rest, "")
  defp contained(_outer, ""), do: false
  defp contained("", _inner), do: false

  defp contained("*" <> rest = outer, <<_first::utf8, inner::binary>> = whole),
    do: contained(rest, whole) or contained(outer, inner)

  defp contained(_outer, "*" <> _inner), do: false
  defp contained("?" <> rest, <<_first::utf8, inner::binary>>), do: contained(rest, inner)

  defp contained(<<char::utf8, rest::binary>>, <<char::utf8, inner::binary>>)
       when char not in [?*, ??],
       do: contained(rest, inner)

  defp contained(_outer, _inner), do: false

  defp reaches?(%Statement{resources: patterns}, resource),
    do: Enum.any?(patterns, &Pattern.covers?(&1, resource))

  defp allows?(%Statement{actions: actions}, action),
    do: Enum.any?(actions, &Pattern.covers?(&1, action))
end
