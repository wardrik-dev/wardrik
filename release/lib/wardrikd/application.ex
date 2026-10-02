defmodule Wardrikd.Application do
  @moduledoc """
  Starts Wardrik for the release, once every package's application is
  running.

  Core's own application would start the store as it boots, before the
  applications of a store kept elsewhere, such as Postgres through
  wardrik_ecto, have started. The release's application depends on all of
  them, so starting Wardrik here starts it last.
  """

  use Application

  @impl Application
  def start(_type, _args),
    do: Supervisor.start_link([Wardrik], strategy: :one_for_one, name: Wardrikd.Supervisor)
end
