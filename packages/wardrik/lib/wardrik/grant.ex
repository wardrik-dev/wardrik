defmodule Wardrik.Grant do
  @moduledoc """
  What its holder may do to the agents under a `Wardrik.AgentID.Prefix`, its
  scope.

      {:ok, grant} = Wardrik.Grant.new(Wardrik.AgentID.Prefix.new!(org: "acme"), [:read, :message])

      Wardrik.Grant.allows?(grant, :message, ~A"acme/@jon/triage")  #=> true
      Wardrik.Grant.allows?(grant, :decide, ~A"acme/@jon/triage")   #=> false

  A scope reaches every agent, an org's, one person's, or one agent with
  every external ID it answers for, and matches at segment boundaries:
  `acme/` never reaches `acmecorp/…`, and `acme/triage` never reaches
  `acme/triage2`.

  ## Actions

  | Action | Lets its holder |
  | --- | --- |
  | `:read` | list the agents, and read their snapshots, definitions and logs |
  | `:message` | send them messages, and cancel what they are doing |
  | `:decide` | approve or reject the calls they wait on |
  | `:define` | put and delete them, and their schedules |
  | `:serve` | offer them tools as a worker |

  `new/1` grants every action.

  ## Its ceiling

  A grant that can `:define` carries a ceiling: the hooks every agent its
  holder defines is held to, ahead of the agent's own. The strictest hook
  decides a call, so what a definition says can narrow its ceiling and never
  loosen it: a ceiling that asks before `github/*` asks, whatever the
  definition allows. An empty ceiling holds its agents to nothing but their
  own hooks.

      {:ok, grant} = Wardrik.Grant.new(Wardrik.AgentID.Prefix.new!(org: "acme"), [:define], WardrikPolicy.hooks(careful))

  `held/2` puts a grant's ceiling ahead of a definition's hooks. An agent
  keeps the ceiling it was defined under, as plain data, until it is defined
  again.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Hook

  @actions [:read, :message, :decide, :define, :serve]
  @named Map.new(@actions, &{Atom.to_string(&1), &1})

  @enforce_keys [:scope, :can]
  defstruct [:scope, :can, ceiling: []]

  @type action() :: :read | :message | :decide | :define | :serve

  @type t() :: %__MODULE__{scope: Prefix.t(), can: [action()], ceiling: [Hook.t()]}

  @doc "Every action, in the order a grant lists them."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  A grant of `can`, actions or their names, on the agents under `scope`, with
  `ceiling` over the agents it defines, or a message saying what does not
  read. Only a grant that can `:define` has a ceiling.
  """
  @spec new(Prefix.t(), [action() | String.t()], [Hook.t()]) ::
          {:ok, t()} | {:error, String.t()}
  def new(%Prefix{} = scope, can \\ @actions, ceiling \\ [])
      when is_list(can) and is_list(ceiling) do
    with {:ok, can} <- actions(can),
         :ok <- ceiling(ceiling, can) do
      {:ok, %__MODULE__{scope: scope, can: can, ceiling: ceiling}}
    end
  end

  defp ceiling([], _can), do: :ok

  defp ceiling(hooks, can) do
    cond do
      not Enum.all?(hooks, &match?(%Hook{}, &1)) ->
        {:error, "A ceiling is a list of Wardrik.Hook"}

      :define not in can ->
        {:error, "A ceiling holds the agents a grant defines, and this one cannot define"}

      true ->
        :ok
    end
  end

  defp actions([]), do: {:error, "A grant allows at least one action"}

  defp actions(can) do
    case Enum.reject(can, &(action(&1) in @actions)) do
      [] ->
        named = Enum.map(can, &action/1)
        {:ok, Enum.filter(@actions, &(&1 in named))}

      [unknown | _rest] ->
        {:error,
         "#{inspect(unknown)} is not an action; the actions are " <>
           Enum.map_join(@actions, ", ", &Atom.to_string/1)}
    end
  end

  defp action(name) when is_binary(name), do: Map.get(@named, name)
  defp action(action), do: action

  @doc "Whether `grant` reaches the agent `id`: whether its scope covers it."
  @spec covers?(t(), AgentID.t()) :: boolean()
  def covers?(%__MODULE__{scope: scope}, %AgentID{} = id), do: Prefix.covers?(scope, id)

  @doc "`hooks`, a definition's own, with `grant`'s ceiling ahead of them."
  @spec held(t(), [Hook.t()] | nil) :: [Hook.t()]
  def held(%__MODULE__{ceiling: ceiling}, hooks), do: ceiling ++ (hooks || [])

  @doc "Whether `grant` lets its holder take `action` on the agent `id`."
  @spec allows?(t(), action(), AgentID.t()) :: boolean()
  def allows?(%__MODULE__{can: can} = grant, action, %AgentID{} = id),
    do: action in can and covers?(grant, id)
end
