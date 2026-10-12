defmodule Wardrik.Caller do
  @moduledoc """
  Who asks for an operation, and what they may do: the `Wardrik.Principal` a
  change is recorded as made by, and the `Wardrik.Grant` that decides whether
  they may make it.

      caller = Wardrik.Caller.new(Wardrik.Principal.new(:user, "jon"), grant)
      {:ok, snapshot} = Wardrik.Query.run(%Wardrik.Operations.ReadAgent{agent: id}, caller)

  A surface knows its callers its own way, by a token, a shell account or a
  chat user, and answers each with one of these.
  """

  alias Wardrik.Grant
  alias Wardrik.Principal

  @enforce_keys [:principal, :grant]
  defstruct [:principal, :grant]

  @type t() :: %__MODULE__{principal: Principal.t() | nil, grant: Grant.t()}

  @doc "A caller known as `principal`, or `nil` where none is known, holding `grant`."
  @spec new(Principal.t() | nil, Grant.t()) :: t()
  def new(principal, %Grant{} = grant), do: %__MODULE__{principal: principal, grant: grant}

  @doc """
  A caller known as `principal` who may do anything to every agent: one who
  holds the node itself, as a shell on it, or the terminal client.
  """
  @spec root(Principal.t() | nil) :: t()
  def root(principal) do
    {:ok, grant} = Grant.new(Wardrik.AgentID.Prefix.all())
    new(principal, grant)
  end
end
