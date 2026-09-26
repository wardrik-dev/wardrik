defmodule Wardrik.Grant do
  @moduledoc """
  What its holder may do to the agents under a scope.

      {:ok, grant} = Wardrik.Grant.new("acme/", [:read, :message])

      Wardrik.Grant.allows?(grant, :message, "acme/jon/triage")  #=> true
      Wardrik.Grant.allows?(grant, :decide, "acme/jon/triage")   #=> false

  A scope is a key prefix that ends at a segment:

  | Scope | Reaches |
  | --- | --- |
  | `""` | every agent |
  | `"acme/"` | the agents of one org |
  | `"acme/jon/"` | one person's agents |
  | `"acme/jon/triage"` | one agent |

  `new/2` writes a scope of one or two segments as the prefix it is, so
  `"acme"` is `"acme/"`, and refuses one with an empty segment or more than
  three. `covers?/2` matches at segment boundaries: `"acme/"` never reaches
  `acmecorp/…`, and `"acme/jon/triage"` never reaches `acme/jon/triage2`.

  ## Actions

  | Action | Lets its holder |
  | --- | --- |
  | `:read` | list the agents, and read their snapshots, definitions and logs |
  | `:message` | send them messages, and cancel what they are doing |
  | `:decide` | approve or reject the calls they wait on |
  | `:define` | put and delete them, and their schedules |
  | `:serve` | offer them tools as a worker |

  `new/1` grants every action.
  """

  @actions [:read, :message, :decide, :define, :serve]
  @named Map.new(@actions, &{Atom.to_string(&1), &1})

  @enforce_keys [:scope, :can]
  defstruct [:scope, :can]

  @type action() :: :read | :message | :decide | :define | :serve

  @type t() :: %__MODULE__{scope: String.t(), can: [action()]}

  @doc "Every action, in the order a grant lists them."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  A grant of `can`, actions or their names, on the agents under `scope`, or a
  message saying what does not read.
  """
  @spec new(String.t(), [action() | String.t()]) :: {:ok, t()} | {:error, String.t()}
  def new(scope, can \\ @actions) when is_binary(scope) and is_list(can) do
    with {:ok, scope} <- scope(scope),
         {:ok, can} <- actions(can) do
      {:ok, %__MODULE__{scope: scope, can: can}}
    end
  end

  defp scope(""), do: {:ok, ""}

  defp scope(scope) do
    trimmed = String.trim_trailing(scope, "/")

    case String.split(trimmed, "/") do
      [org] when org != "" ->
        {:ok, trimmed <> "/"}

      [org, user] when org != "" and user != "" ->
        {:ok, trimmed <> "/"}

      [org, user, name] when org != "" and user != "" and name != "" ->
        {:ok, trimmed}

      _other ->
        {:error,
         "#{inspect(scope)} is not a scope; a scope is org/, org/user/ or a key, org/user/name"}
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

  @doc """
  Whether `grant` reaches the agent under `key`: its scope is empty, or the
  key is the scope, or goes on from it at a `/`.
  """
  @spec covers?(t(), String.t()) :: boolean()
  def covers?(%__MODULE__{scope: ""}, key) when is_binary(key), do: true

  def covers?(%__MODULE__{scope: scope}, key) when is_binary(key),
    do: String.starts_with?(key <> "/", String.trim_trailing(scope, "/") <> "/")

  @doc "Whether `grant` lets its holder take `action` on the agent under `key`."
  @spec allows?(t(), action(), String.t()) :: boolean()
  def allows?(%__MODULE__{can: can} = grant, action, key),
    do: action in can and covers?(grant, key)
end
