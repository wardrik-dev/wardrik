defmodule MyApp.Accounts.User do
  @moduledoc "Stands in for the application's own users: who signed in, and their org."

  @enforce_keys [:id, :org, :email]
  defstruct [:id, :org, :email]
end
