defmodule WardrikWorkspace.Share do
  @moduledoc """
  A tree the deployment lets agents beyond its owner mount: the agents each
  `Wardrik.Resource` pattern of `read` covers may read it, and those each of
  `write` covers may read and change it. Its owner's agents mount it as
  they always may.

      # config.yaml
      workspace:
        shared:
          acme/runbooks:
            read: ["acme/*"]                         # every agent in acme, its users' included
            write: [acme/agent/ops, "acme/agent/ops/*"]  # and the org's ops agent, in every thread

  An agent still names the trees it mounts in its own definition; a share
  only says who else may. See `WardrikWorkspace.Spec`.
  """

  alias Wardrik.AgentID
  alias Wardrik.Resource
  alias WardrikWorkspace.Spec

  @enforce_keys [:tree]
  defstruct [:tree, read: [], write: []]

  @type t() :: %__MODULE__{tree: String.t(), read: [Resource.t()], write: [Resource.t()]}

  @doc """
  The share of `tree`, read by the agents `:read` covers and changed by
  those `:write` covers, each a pattern or its text, or why it does not read.
  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(tree, opts) when is_binary(tree) do
    opts = Keyword.validate!(opts, read: [], write: [])

    with {:ok, tree} <- Spec.tree("shared " <> tree, tree),
         {:ok, read} <- patterns(tree, "read", opts[:read]),
         {:ok, write} <- patterns(tree, "write", opts[:write]) do
      {:ok, %__MODULE__{tree: tree, read: read, write: write}}
    end
  end

  defp patterns(tree, key, patterns) when is_list(patterns) do
    patterns
    |> Enum.reduce_while({:ok, []}, fn pattern, {:ok, read} ->
      case pattern(pattern) do
        {:ok, pattern} -> {:cont, {:ok, [pattern | read]}}
        {:error, message} -> {:halt, {:error, "#{tree} #{key}: #{message}"}}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      error -> error
    end
  end

  defp patterns(tree, key, _patterns), do: {:error, "#{tree} #{key} is a list of patterns"}

  defp pattern(%Resource{} = pattern), do: {:ok, pattern}
  defp pattern(text) when is_binary(text), do: Resource.parse(text)
  defp pattern(other), do: {:error, "#{inspect(other)} is not a pattern"}

  @doc """
  How `shares` let the agent `id` mount `tree`: `{:ok, :write}`, `{:ok,
  :read}`, or `:error` where none lets it.
  """
  @spec mode([t()], String.t(), AgentID.t()) :: {:ok, :read | :write} | :error
  def mode(shares, tree, %AgentID{} = id) do
    shared = for %__MODULE__{tree: ^tree} = share <- shares, do: share

    cond do
      Enum.any?(shared, &covered?(&1.write, id)) -> {:ok, :write}
      Enum.any?(shared, &covered?(&1.read, id)) -> {:ok, :read}
      true -> :error
    end
  end

  defp covered?(patterns, id),
    do: Enum.any?(patterns, &Resource.covers?(&1, AgentID.resource(id)))
end
