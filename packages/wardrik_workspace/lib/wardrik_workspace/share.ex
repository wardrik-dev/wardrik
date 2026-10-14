defmodule WardrikWorkspace.Share do
  @moduledoc """
  A tree the deployment lets agents beyond its owner mount: the agents under
  each prefix of `read` may read it, and those under each of `write` may
  read and change it. Its owner's agents mount it as they always may.

      # config.yaml
      workspace:
        shared:
          acme/runbooks:
            read: ["acme/*"]       # every agent in acme, its users' included
            write: [acme/ops]      # and the org's ops agent changes it

  An agent still names the trees it mounts in its own definition; a share
  only says who else may. See `WardrikWorkspace.Spec`.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias WardrikWorkspace.Spec

  @enforce_keys [:tree]
  defstruct [:tree, read: [], write: []]

  @type t() :: %__MODULE__{tree: String.t(), read: [Prefix.t()], write: [Prefix.t()]}

  @doc """
  The share of `tree`, read by the agents under `:read` and changed by those
  under `:write`, each a prefix or its text, or why it does not read.
  """
  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(tree, opts) when is_binary(tree) do
    opts = Keyword.validate!(opts, read: [], write: [])

    with {:ok, tree} <- Spec.tree("shared " <> tree, tree),
         {:ok, read} <- prefixes(tree, "read", opts[:read]),
         {:ok, write} <- prefixes(tree, "write", opts[:write]) do
      {:ok, %__MODULE__{tree: tree, read: read, write: write}}
    end
  end

  defp prefixes(tree, key, prefixes) when is_list(prefixes) do
    prefixes
    |> Enum.reduce_while({:ok, []}, fn prefix, {:ok, read} ->
      case prefix(prefix) do
        {:ok, prefix} -> {:cont, {:ok, [prefix | read]}}
        {:error, message} -> {:halt, {:error, "#{tree} #{key}: #{message}"}}
      end
    end)
    |> case do
      {:ok, read} -> {:ok, Enum.reverse(read)}
      error -> error
    end
  end

  defp prefixes(tree, key, _prefixes), do: {:error, "#{tree} #{key} is a list of prefixes"}

  defp prefix(%Prefix{} = prefix), do: {:ok, prefix}
  defp prefix(text) when is_binary(text), do: Prefix.parse(text)
  defp prefix(other), do: {:error, "#{inspect(other)} is not a prefix"}

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

  defp covered?(prefixes, id), do: Enum.any?(prefixes, &Prefix.covers?(&1, id))
end
