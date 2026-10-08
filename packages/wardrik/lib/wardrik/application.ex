defmodule Wardrik.Application do
  @moduledoc false

  # The one place core reads its application environment: the store and the
  # fleet, for the default start, which a host starting Wardrik itself passes.

  use Application

  @impl true
  def start(_type, _args) do
    case Application.get_env(:wardrik, :start, :application) do
      :application ->
        Wardrik.start_link(
          store: Application.get_env(:wardrik, Wardrik.Store, []),
          fleet: Application.get_env(:wardrik, Wardrik.Fleet, [])
        )

      :host ->
        Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end
end
