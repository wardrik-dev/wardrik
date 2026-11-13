defmodule WardrikDaemon.Web.SecretSettings do
  @moduledoc false

  # Gives the dashboard's Secrets page each owner's secrets. Values are sealed and never listed.

  @behaviour WardrikWeb.Settings

  alias WardrikDaemon.Web.Settings

  @purposes WardrikProtocol.schema("secret_input")["properties"]["purpose"]["enum"]

  @impl true
  def owners(scope, _opts), do: WardrikDaemon.Settings.owners(Settings.daemon(), scope)

  @impl true
  def list(scope, owner, _opts) do
    with {:ok, %{"secrets" => secrets}} <- Wardrik.run(scope, "secrets.list", %{"owner" => owner}),
         do: {:ok, secrets}
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
        "purpose" => %{"enum" => @purposes},
        "value" => %{"type" => "string", "writeOnly" => true}
      }
    }

  @impl true
  def add(scope, owner, %{"name" => name, "purpose" => purpose, "value" => value}, _opts) do
    input = %{
      "owner" => owner,
      "name" => String.trim(name),
      "purpose" => purpose,
      "value" => value
    }

    with {:ok, nil} <- Wardrik.run(scope, "secrets.put", input),
         do: {:ok, %{"name" => input["name"], "purpose" => purpose}}
  end

  def add(_scope, _owner, _input, _opts), do: {:error, "Enter a name, a purpose and a value."}

  @impl true
  def remove(scope, owner, name, _opts) do
    with {:ok, nil} <- Wardrik.run(scope, "secrets.delete", %{"owner" => owner, "name" => name}),
         do: :ok
  end
end
