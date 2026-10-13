defmodule Wardrik.Grants do
  @moduledoc """
  What each person or system that reaches a deployment may do: the
  `Wardrik.Grant`s its host gives a `Wardrik.Principal`, however they came.

  A host names the module once, as `Wardrik`'s `:grants`, and whatever
  knows someone by their principal alone asks it through `caller/2`:

      children = [{Wardrik, grants: MyApp.Grants}]

      {:ok, caller} = Wardrik.Grants.caller(principal, ~A"acme/triage")
      Wardrik.Command.run(%Wardrik.Operations.Decide{agent: ~A"acme/triage", decisions: decisions}, caller)

  A chat channel knows the person pressing a button by their principal, and
  a tool acting for the person who asked for its turn knows them as
  `Wardrik.Tool.Context`'s `:sender`. Where a host answers who someone is in
  one place, every surface holds them to the same grants. A surface that
  holds a grant itself, as the HTTP API does in its tokens, need not ask.

  A principal may hold several grants, each on its own scope, as someone
  in a channel that offers several orgs' agents holds one in each.

  Without a module nobody holds anything, and `caller/2` is `:unsupported`.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Principal

  @doc "What `principal` may do, as one grant on each scope they reach; `[]` for nothing."
  @callback grants(principal :: Principal.t()) :: [Grant.t()]

  @module {__MODULE__, :module}

  @doc """
  Keeps `module`, or `nil` for none, as the host's. Answers `:ignore`, so
  `Wardrik` runs it as a child that starts nothing.
  """
  @spec configure(module() | nil) :: :ignore
  def configure(module) when is_atom(module) do
    :persistent_term.put(@module, module)
    :ignore
  end

  @doc "The host's module, or an `:unsupported` error where none was named."
  @spec module() :: {:ok, module()} | {:error, Error.t()}
  def module do
    case :persistent_term.get(@module, nil) do
      nil -> {:error, Error.new(:unsupported, "This server grants nobody anything.")}
      module -> {:ok, module}
    end
  end

  @doc """
  `principal` as a caller of an operation on `subject`, an agent or the
  agents under a prefix: holding the first of their grants whose scope
  reaches it. `:not_found` where none does, or where nobody is known, as a
  turn nobody asked for: a subject outside a caller's reach is one that
  does not exist to them.
  """
  @spec caller(Principal.t() | nil, AgentID.t() | Prefix.t()) ::
          {:ok, Caller.t()} | {:error, Error.t()}
  def caller(principal, subject) do
    with {:ok, module} <- module() do
      case Enum.find(granted(module, principal), &Prefix.covers?(&1.scope, subject)) do
        %Grant{} = grant ->
          {:ok, Caller.new(principal, grant)}

        nil ->
          {:error, Error.new(:not_found, "Nothing at #{subject} is within this caller's reach.")}
      end
    end
  end

  defp granted(_module, nil), do: []
  defp granted(module, principal), do: module.grants(principal)
end
