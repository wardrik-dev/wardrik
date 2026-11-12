defmodule WardrikWeb.Test.Servers do
  @moduledoc "A `WardrikWeb.Settings` that keeps servers in an Agent, for tests."
  @behaviour WardrikWeb.Settings

  def start, do: Agent.start(fn -> fixed() end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _items -> fixed() end)

  defp fixed,
    do: [
      %{
        "owner" => "acme",
        "name" => "github",
        "url" => "https://gh.test/mcp",
        "fixed" => "Set in config.yaml"
      },
      %{
        "owner" => "acme",
        "name" => "crm",
        "url" => "https://crm.test/mcp",
        "tools" => ["a", "b"]
      },
      %{"owner" => "deployment", "name" => "search", "url" => nil}
    ]

  @impl true
  def owners(_scope, _opts), do: ["acme", "ana"]

  @impl true
  def list(_scope, "nobody", _opts), do: {:error, Wardrik.Error.new(:forbidden, "Not yours.")}

  def list(_scope, owner, _opts) do
    items = Agent.get(__MODULE__, & &1)
    {:ok, Enum.filter(items, &(&1["owner"] in [owner, "deployment"]))}
  end

  @impl true
  def columns(_opts), do: [{"URL", "url"}, {"Tools", "tools"}, {"Headers", "headers"}]

  @impl true
  def schema(_opts),
    do: %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "url" => %{"type" => "string"},
        "token" => %{"type" => "string", "writeOnly" => true}
      }
    }

  @impl true
  def add(_scope, _owner, %{"name" => "bad"}, _opts), do: {:error, "That name is taken."}

  def add(_scope, owner, input, _opts) do
    item = Map.merge(%{"owner" => owner}, Map.delete(input, "token"))
    Agent.update(__MODULE__, &(&1 ++ [item]))
    {:ok, item}
  end

  @impl true
  def remove(_scope, _owner, "github", _opts),
    do: {:error, Wardrik.Error.new(:forbidden, "It's in config.yaml.")}

  def remove(_scope, owner, name, _opts) do
    Agent.update(
      __MODULE__,
      &Enum.reject(&1, fn item -> item["owner"] == owner and item["name"] == name end)
    )

    :ok
  end
end

defmodule WardrikWeb.Test.Secrets do
  @moduledoc "A `WardrikWeb.Settings` with one secret and a common field list, for tests."
  @behaviour WardrikWeb.Settings

  @impl true
  def owners(_scope, _opts), do: ["acme"]

  @impl true
  def list(_scope, _owner, _opts), do: {:ok, [%{"name" => "API_KEY", "purpose" => "api_key"}]}

  @impl true
  def columns(_opts), do: [{"Purpose", "purpose"}]

  @impl true
  def schema(_opts),
    do: %{
      "type" => "object",
      "required" => ["name", "value"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "purpose" => %{"enum" => ["api_key", "header"]},
        "value" => %{"type" => "string", "writeOnly" => true}
      }
    }

  @impl true
  def common(_opts), do: ~w(name purpose value)

  @impl true
  def add(_scope, _owner, input, _opts), do: {:ok, Map.delete(input, "value")}

  @impl true
  def remove(_scope, _owner, _name, _opts), do: :ok
end

defmodule WardrikWeb.Test.Connections do
  @moduledoc "A `WardrikWeb.Connections` that keeps connections in an Agent, for tests."
  @behaviour WardrikWeb.Connections

  def start, do: Agent.start(fn -> fixed() end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _connections -> fixed() end)

  def connected(provider),
    do: Agent.update(__MODULE__, &Map.put(&1, provider, %{"connected" => true}))

  defp fixed,
    do: %{
      "google" => %{"connected" => true},
      "github" => %{},
      "slack" => %{"signing_in" => true},
      "linear" => %{}
    }

  @impl true
  def list(_scope, _opts) do
    connections = Agent.get(__MODULE__, & &1)

    {:ok,
     for({provider, state} <- Enum.sort(connections), do: Map.put(state, "provider", provider))}
  end

  @impl true
  def connect(_scope, "google", _opts), do: {:ok, %{"provider" => "google", "connected" => true}}

  def connect(_scope, "github", _opts),
    do:
      {:ok,
       %{
         "provider" => "github",
         "authorization" => %{"url" => "https://github.test/device", "code" => "ABCD-1234"}
       }}

  def connect(_scope, "linear", _opts),
    do:
      {:ok, %{"provider" => "linear", "authorization" => %{"url" => "https://linear.test/auth"}}}

  def connect(_scope, provider, _opts), do: {:error, "#{provider} isn't set up."}

  @impl true
  def pair(_scope, "linear", "GOOD", _opts), do: connected("linear")

  def pair(_scope, _provider, _code, _opts),
    do: {:error, Wardrik.Error.new(:invalid_request, "Wrong code.")}

  @impl true
  def disconnect(_scope, "slack", _opts), do: {:error, "Slack can't be disconnected."}

  def disconnect(_scope, provider, _opts),
    do: Agent.update(__MODULE__, &Map.put(&1, provider, %{}))
end
