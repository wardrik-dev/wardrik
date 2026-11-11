defmodule WardrikDaemon.Web.SecretSettings do
  @moduledoc false

  # Gives the dashboard's Secrets page each owner's secrets. Values are sealed and never listed.

  @behaviour WardrikWeb.Settings

  alias WardrikCore.Principal
  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Secrets
  alias WardrikDaemon.Web.Settings
  alias WardrikVault.Secret

  @impl true
  def owners(scope, _opts), do: Settings.choices(Settings.daemon(), scope)

  @impl true
  def list(scope, owner, _opts) do
    daemon = Settings.daemon()

    with :ok <- Allowed.owned(daemon, scope, owner, {"secret.read", :secret}),
         do: {:ok, Secrets.list(daemon.wardrik, owner)}
  end

  @impl true
  def columns(_opts), do: [{"Purpose", "purpose"}]

  @impl true
  def schema(_opts),
    do: %{
      "type" => "object",
      "required" => ["name", "purpose", "value"],
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "If a secret with this name exists, its value is replaced."
        },
        "purpose" => %{"enum" => Enum.sort(Secrets.purposes())},
        "value" => %{"type" => "string", "writeOnly" => true}
      }
    }

  @impl true
  def add(scope, owner, %{"name" => name, "purpose" => purpose, "value" => value}, _opts) do
    daemon = Settings.daemon()
    secret = %Secret{principal: %Principal{id: owner}, name: String.trim(name), value: value}

    with :ok <- Allowed.owned(daemon, scope, owner, {"secret.put", :secret}),
         :ok <-
           stored(Secrets.put(daemon.wardrik, secret, purpose: purpose, actor: scope.principal)) do
      {:ok, %{"name" => secret.name, "purpose" => purpose}}
    end
  end

  def add(_scope, _owner, _input, _opts), do: {:error, "Enter a name, a purpose and a value."}

  @impl true
  def remove(scope, owner, name, _opts) do
    daemon = Settings.daemon()

    with :ok <- Allowed.owned(daemon, scope, owner, {"secret.delete", :secret}),
         do: stored(Secrets.delete(daemon.wardrik, {owner, name}, scope.principal))
  end

  defp stored(:ok), do: :ok
  defp stored({:error, reason}), do: {:error, "The vault refused: #{inspect(reason)}."}
end
