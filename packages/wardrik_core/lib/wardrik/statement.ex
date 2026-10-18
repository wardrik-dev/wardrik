defmodule Wardrik.Statement do
  @moduledoc """
  What a `Wardrik.Token` allows: its `actions`, on its `resources`. A
  token's scope is a list of statements, and it allows what any one of them
  does; anything none states is denied.

      %Wardrik.Statement{
        actions: ["agent.read", "agent.ask"],
        resources: [Wardrik.AgentID.Prefix.new!(org: "acme")]
      }

  An action is what is done, by the name of the function of `Wardrik` that
  does it, `.` for `_`: `agent.ask`, `agents.list`. `agent.*` is every
  action on one agent, and `*` every action there is. `Wardrik.Role` names
  the sets of them a person is usually given.

  A resource is the agents under a `Wardrik.AgentID.Prefix`; it says what
  each reaches.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix

  @enforce_keys [:actions, :resources]
  defstruct [:actions, :resources]

  @type action() :: String.t()
  @typedoc "What an action is taken on: one agent, or every agent under a prefix."
  @type target() :: AgentID.t() | Prefix.t()
  @type t() :: %__MODULE__{actions: [action()], resources: [Prefix.t()]}

  @doc "Whether `statement` names `action`, itself or under a wildcard."
  @spec allows?(t(), action()) :: boolean()
  def allows?(%__MODULE__{actions: actions}, action) when is_binary(action),
    do: Enum.any?(actions, &covers?(&1, action))

  @doc "Whether `statement` reaches `target`: one agent, or every agent under a prefix."
  @spec reaches?(t(), target()) :: boolean()
  def reaches?(%__MODULE__{resources: resources}, target),
    do: Enum.any?(resources, &Prefix.covers?(&1, target))

  @doc """
  What both `statement` and `other` allow, as a statement, or none: the
  actions both name, a wildcard's narrower where one names the other's, on
  what both reach, the narrower of two resources where one covers the other.
  """
  @spec intersect(t(), t()) :: [t()]
  def intersect(%__MODULE__{} = statement, %__MODULE__{} = other) do
    case {both(statement.actions, other.actions, &covers?/2),
          both(statement.resources, other.resources, &Prefix.covers?/2)} do
      {[_ | _] = actions, [_ | _] = resources} ->
        [%__MODULE__{actions: actions, resources: resources}]

      _apart ->
        []
    end
  end

  defp both(ones, others, covers?) do
    Enum.uniq(
      for one <- ones,
          other <- others,
          narrower <- narrower(one, other, covers?),
          do: narrower
    )
  end

  defp narrower(one, other, covers?) do
    cond do
      covers?.(one, other) -> [other]
      covers?.(other, one) -> [one]
      true -> []
    end
  end

  defp covers?("*", _action), do: true

  defp covers?(pattern, action) do
    pattern == action or
      (String.ends_with?(pattern, ".*") and
         String.starts_with?(action, String.trim_trailing(pattern, "*")))
  end
end
