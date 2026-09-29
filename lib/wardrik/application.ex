defmodule Wardrik.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    case Application.get_env(:wardrik, :start, :application) do
      :application -> Wardrik.start_link()
      :host -> Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end
end
