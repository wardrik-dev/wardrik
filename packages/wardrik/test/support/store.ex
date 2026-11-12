defmodule Wardrik.Test.Store do
  @moduledoc """
  The store a test keeps its Wardrik in: in memory, or in Postgres where `DATABASE_URL` is set,
  under a scope of the test's own, so tests that share the table never meet.
  """

  @doc "Starts the Postgres store the suite shares, where `DATABASE_URL` is set."
  def start do
    with url when is_binary(url) <- System.get_env("DATABASE_URL") do
      children = [{Wardrik.Store, Wardrik.Store.Ecto.new(url: url)}]
      {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    end
  end

  @doc "Returns a store named `name`, of the test's own."
  def new(name) do
    if System.get_env("DATABASE_URL"),
      do:
        Wardrik.Store.scope(
          Wardrik.Store.Ecto.new(repo: Wardrik.Store.Ecto.Repo),
          "t#{System.unique_integer([:positive])}"
        ),
      else: Wardrik.Store.ETS.new(name: name)
  end
end
