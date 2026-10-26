defmodule Wardrik.Audit do
  @moduledoc """
  The operations on the deployment's audit, and how a package records a change in it.

      Wardrik.Audit.list(scope, limit: 50)
      #=> {:ok, %Wardrik.Page{events: [%Wardrik.Event{type: "wardrik.agent.defined", ...}], next: 1}}
  """

  use Wardrik.Operations.Functions, prefix: "audit"

  alias Wardrik.Instance
  alias Wardrik.Scope

  @doc """
  Records a change the scope's principal made, as `wardrik.<type>`, about `subject`, with `data` as
  the protocol's schema for the type describes it.

      Wardrik.Audit.record(scope, "room.bound", "channels/slack/C1", %{"channel" => "slack", ...})
      #=> :ok
  """
  @spec record(Scope.t(), String.t(), String.t(), map()) :: :ok
  def record(%Scope{wardrik: instance, principal: principal}, type, subject, data) do
    events = instance |> Instance.fetch!() |> Wardrik.events()
    :ok = WardrikEvents.record(events, {type, subject, data}, actor: principal)
  end
end
