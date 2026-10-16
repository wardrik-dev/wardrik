defmodule Wardrik.Query do
  @moduledoc """
  An operation that reads, and changes nothing.

  A query is a struct whose module implements this and an operation over
  what it reads, such as `Wardrik.AgentOperation`. Every surface runs one
  through `run/2`, which checks the caller's grant before the module reads
  anything:

      {:ok, snapshot} = Wardrik.Query.run(%Wardrik.Operations.ReadAgent{agent: id}, caller)

  What a query answers is what `Wardrik.Resource` shapes, as `JSON.encode!/1`
  takes it, so every surface answers alike.
  """

  alias Wardrik.Caller
  alias Wardrik.Error

  @doc "What `request` reads, for `caller`, whose grant allows it."
  @callback run(request :: struct(), caller :: Caller.t()) ::
              {:ok, term()} | {:error, Error.t()}

  @doc """
  What `request` reads, where `caller`'s grant allows the module's action on
  its subject, or why not.
  """
  @spec run(struct(), Caller.t()) :: {:ok, term()} | {:error, Error.t()}
  def run(%module{} = request, %Caller{} = caller) do
    with :ok <- Wardrik.Subject.authorize(module.subject(request), caller.grant, module.action()),
         do: module.run(request, caller)
  end
end
