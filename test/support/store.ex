defmodule Wardrik.Test.Store do
  @moduledoc """
  The store a test keeps its Wardrik in: in memory, or in Postgres where `DATABASE_URL` is set,
  under a scope of the test's own, so tests that share the table never meet.
  """

  @doc "Starts the Postgres store the suite shares, where `DATABASE_URL` is set."
  def start do
    with url when is_binary(url) <- System.get_env("DATABASE_URL") do
      children = [{WardrikStore, WardrikStore.Ecto.new(url: url)}]
      {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    end
  end

  @doc "Returns a store named `name`, of the test's own."
  def new(name) do
    if System.get_env("DATABASE_URL"),
      do:
        WardrikStore.scope(
          WardrikStore.Ecto.new(repo: WardrikStore.Ecto.Repo),
          "t#{System.unique_integer([:positive])}"
        ),
      else: WardrikStore.ETS.new(name: name)
  end
end
