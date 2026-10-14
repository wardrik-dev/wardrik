defmodule Wardrik.Command do
  @moduledoc """
  An operation that changes something, in two steps: `plan/2` says what the
  change is, as a `Wardrik.Change`, and `make/2` makes it.

  A command is a struct whose module implements this and an operation over
  what it changes, such as `Wardrik.AgentOperation`. Every surface runs one
  through this module, which checks the caller's grant at each step, and
  records the change in `Wardrik.Audit`, with the caller's principal, once it
  is made:

      {:ok, change} = Wardrik.Command.plan(%Wardrik.Operations.Cancel{agent: id}, caller)
      {:ok, answer} = Wardrik.Command.make(change, caller)

  `run/2` does both. A plan makes nothing happen, so a surface may show it
  first, as `preview/1` gives it, or keep it until a person agrees to it;
  `make/2` checks the grant again, since it may come much later, and does
  what the plan's `Wardrik.Effect` says. What the audit records is what the
  change made, as that effect's entries, all under one trace.
  """

  alias Wardrik.Audit
  alias Wardrik.Caller
  alias Wardrik.Change
  alias Wardrik.Effect
  alias Wardrik.Error
  alias Wardrik.Host

  @typedoc """
  What a change answers once it is made: `:created` where it made something
  that was not there, as an agent or a trigger. A change with nothing to say
  answers `{:ok, nil}`.
  """
  @type answer() :: {:ok, term()} | {:created, term()}

  @doc """
  The change `request` would make, for `caller`, whose grant allows it, or
  why it cannot be made. It makes nothing happen.
  """
  @callback plan(request :: struct(), caller :: Caller.t()) ::
              {:ok, Change.t()} | {:error, Error.t()}

  @doc """
  Makes `change`, for `caller`, whose grant allows it: what it answers, and
  the `Wardrik.Effect` it made, which is the change's own unless part of it
  could not be made.
  """
  @callback make(change :: Change.t(), caller :: Caller.t()) ::
              {:ok | :created, term(), Wardrik.Effect.t()} | {:error, Error.t()}

  @doc "Plans `request`, and makes the change."
  @spec run(struct(), Caller.t()) :: answer() | {:error, Error.t()}
  def run(request, %Caller{} = caller) do
    with {:ok, change} <- plan(request, caller), do: make(change, caller)
  end

  @doc """
  The change `request` would make, where `caller`'s grant allows the module's
  action on its subject, or why not.
  """
  @spec plan(struct(), Caller.t()) :: {:ok, Change.t()} | {:error, Error.t()}
  def plan(%module{} = request, %Caller{} = caller) do
    with :ok <- authorize(request, caller), do: module.plan(request, caller)
  end

  @doc "What `change` will do, as every surface shows it before it is made."
  @spec preview(Change.t()) :: map()
  def preview(%Change{effect: effect}), do: Effect.preview(effect)

  @doc """
  Makes `change`, where `caller`'s grant still allows it, and records what
  it made in the audit, every entry under one trace.
  """
  @spec make(Change.t(), Caller.t()) :: answer() | {:error, Error.t()}
  def make(%Change{request: %module{} = request} = change, %Caller{} = caller) do
    with :ok <- authorize(request, caller),
         {result, answer, made} when result in [:ok, :created] <- module.make(change, caller) do
      :ok = Audit.record_all(Host.audit(caller.host), Effect.audit(made), by: caller.principal)
      {result, answer}
    end
  end

  defp authorize(%module{} = request, caller),
    do: Wardrik.Subject.authorize(module.subject(request), caller.grant, module.action())
end
