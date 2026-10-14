defmodule Wardrik.Application do
  @moduledoc false

  # The one place core reads its application environment: the store, the
  # fleet and the host's seams, for the default start, which a host starting
  # Wardrik itself passes. The store starts first, and Wardrik after it.

  use Application

  @impl true
  def start(_type, _args) do
    case Application.get_env(:wardrik, :start, :application) do
      :application ->
        store = WardrikStore.new(Application.get_env(:wardrik, WardrikStore, []))
        seams = Wardrik.Host.configured(Application.get_env(:wardrik, Wardrik.Host, []))
        host = Wardrik.Host.new([store: store] ++ seams)
        fleet = Application.get_env(:wardrik, Wardrik.Fleet, [])

        Supervisor.start_link([{WardrikStore, store}, {Wardrik, fleet: fleet, host: host}],
          strategy: :rest_for_one,
          name: __MODULE__
        )

      :host ->
        Supervisor.start_link([], strategy: :one_for_one)
    end
  end
end
