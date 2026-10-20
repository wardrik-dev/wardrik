defmodule MyApp.Agents do
  @moduledoc "Wardrik in this app: who each user is to it, and what they may do with agents."

  use Wardrik, otp_app: :my_app

  @impl Wardrik
  def principal(%MyApp.Accounts.User{org: org, id: id, email: email}),
    do: %{org: org, id: id, name: email}

  # Each user owns their own agents, and reads and messages their org's.
  @impl Wardrik
  def grants(_who), do: [owner: :own, reader: :org, messenger: :org]

  @impl Wardrik
  def authenticate(conn), do: MyAppWeb.Session.user(conn)

  @doc "What `user`'s `agent` is doing, as someone would say it."
  def doing(user, agent) do
    with {:ok, snapshot} <- get(user, agent) do
      {:ok,
       Wardrik.Agent.Activity.Presenter.label(
         %Wardrik.Agent.Activity.English{},
         snapshot.status.activity
       )}
    end
  end
end
