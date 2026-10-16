defmodule Wardrik.Servers.Key do
  @moduledoc """
  An MCP server as agents name it: whose it is, and its name among theirs.

  The deployment's own servers, the ones its configuration lists, belong to
  every agent's prefix, `Wardrik.AgentID.Prefix.all/0`, and are written by
  their name alone:

      Wardrik.Servers.Key.deployment("github")   # github
      Wardrik.Servers.Key.new(acme, "crm")       # acme/crm

  A key is plain data, so a tool source naming one travels with the agent it
  was built for.
  """

  alias Wardrik.AgentID.Prefix

  @enforce_keys [:owner, :name]
  defstruct [:owner, :name]

  @type t() :: %__MODULE__{owner: Prefix.t(), name: String.t()}

  @doc "The server `name` among `owner`'s."
  @spec new(Prefix.t(), String.t()) :: t()
  def new(owner, name) when is_binary(name), do: %__MODULE__{owner: owner, name: name}

  @doc "The deployment's own server `name`."
  @spec deployment(String.t()) :: t()
  def deployment(name), do: new(Prefix.all(), name)

  defimpl String.Chars do
    def to_string(%{owner: owner, name: name}), do: "#{owner}#{name}"
  end
end
