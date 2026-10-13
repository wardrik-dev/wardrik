defmodule Wardrik.Application do
  @moduledoc false

  # The one place core reads its application environment: the store, the
  # fleet and the host's seams, for the default start, which a host starting
  # Wardrik itself passes.

  use Application

  @impl true
  def start(_type, _args) do
    case Application.get_env(:wardrik, :start, :application) do
      :application ->
        Wardrik.start_link(
          store: Application.get_env(:wardrik, WardrikStore, []),
          fleet: Application.get_env(:wardrik, Wardrik.Fleet, []),
          host: Wardrik.Host.new(Application.get_env(:wardrik, Wardrik.Host, []))
        )

      :host ->
        Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end
end
