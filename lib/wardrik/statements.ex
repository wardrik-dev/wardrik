defmodule Wardrik.Statements do
  @moduledoc """
  The authorizer that decides by the `Wardrik.Statement`s a scope holds as its grants. Anything no
  statement allows is refused.

      scope = Wardrik.as(wardrik, principal, [Wardrik.Statement.new(roles: [:reader], resources: ["acme/agent/*"])])
  """

  @behaviour Wardrik.Authorizer

  alias Wardrik.Scope
  alias Wardrik.Statement
  alias WardrikEvents.Pattern

  @impl Wardrik.Authorizer
  def authorize(_config, %Scope{grants: statements}, action, resource) do
    reaching = Enum.filter(statements, &reaches?(&1, resource))

    cond do
      reaching == [] -> {:error, :not_found}
      Enum.any?(reaching, &allows?(&1, action)) -> :ok
      true -> {:error, :forbidden}
    end
  end

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
  Returns whether every name the pattern `inner` covers, `outer` covers too, as `acme/*` covers
  `acme/agent/*` and `acme/a*` covers `acme/a?`, though `acme/a?` doesn't cover `acme/a*`.
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
