defmodule Wardrik.Vault.TestGrants do
  @moduledoc "Grants the tests give a vault: each callback tells the test, and answers as told."
  @behaviour Wardrik.Vault.Grants

  @impl Wardrik.Vault.Grants
  def renew(%{name: name, grant: grant}, test) do
    send(test, {:renew, name, grant})
    {:ok, "renewed " <> grant.value}
  end

  @impl Wardrik.Vault.Grants
  def ask(%{name: name, principal: principal}, test) do
    send(test, {:ask, name, principal.id})
    {:authorize, "https://example.com/authorize/#{name}"}
  end

  @impl Wardrik.Vault.Grants
  def refused(%{name: name}, test) do
    send(test, {:refused, name})
    :ok
  end
end
