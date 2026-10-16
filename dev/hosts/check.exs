# What dev/hosts.sh runs inside each application it makes, as
# `mix run check.exs`, so it runs against the application as it runs: the
# store it keeps Wardrik in passes WardrikStore.Conformance, an agent spawned
# in its fleet is kept there, what it leaves out of its dependencies is not
# loaded, and the budgets and triggers Wardrik runs keep in that store.
#
#   WARDRIK_HOST           the application's module whose store/0 is Wardrik's store
#   WARDRIK_HOST_STORE     the adapter the application configured
#   WARDRIK_HOST_WITHOUT   modules it must not have, separated by commas
#   WARDRIK_HOST_REPO      the application's repo, where the store is kept in it
#   WARDRIK_HOST_TREE      what it starts after Wardrik: agents for the embedding
#                          guide's code
#   WARDRIK_HOST_APP       the application's namespace, where it runs the guide's code

ExUnit.start(autorun: false)

defmodule WardrikHost do
  @moduledoc false
  def store, do: Module.concat([System.fetch_env!("WARDRIK_HOST")]).store()

  def tree?(part), do: part in String.split(System.get_env("WARDRIK_HOST_TREE", ""), ",")
end

defmodule WardrikHost.StoreTest do
  use ExUnit.Case, async: false
  use WardrikStore.Conformance

  setup_all do
    %{store: WardrikHost.store()}
  end
end

defmodule WardrikHost.FleetTest do
  use ExUnit.Case, async: false

  test "the store is the one the application configured" do
    assert inspect(WardrikHost.store().__struct__) == System.fetch_env!("WARDRIK_HOST_STORE")
  end

  test "what the application does not depend on is not loaded" do
    for name <- String.split(System.get_env("WARDRIK_HOST_WITHOUT", ""), ",", trim: true) do
      refute Code.ensure_loaded?(Module.concat([name])), "#{name} is loaded"
    end
  end

  test "an agent spawned in the fleet is kept in the application's store" do
    name = "host-#{System.unique_integer([:positive])}"
    id = Wardrik.AgentID.new!(name, org: "host")

    assert {:ok, _pid} = Wardrik.Fleet.spawn(id)
    assert id in Enum.map(Wardrik.Fleet.list(), & &1.id)

    assert Enum.any?(
             WardrikStore.keys(WardrikHost.store(), :durable, Wardrik.Fleet.prefix()),
             &(&1 =~ name)
           )

    if repo = System.get_env("WARDRIK_HOST_REPO") do
      %{rows: rows} =
        Module.concat([repo]).query!("SELECT key FROM wardrik_records WHERE key LIKE $1", [
          "%#{name}%"
        ])

      assert rows != [], "nothing of #{name} is in #{repo}'s wardrik_records"
    end
  end
end

defmodule WardrikHost.TreeTest do
  use ExUnit.Case, async: false

  test "an agent held to a budget is kept, and a budget's meter counts in the store" do
    policy = WardrikPolicy.decode!(%{"budget" => %{"usd" => 1}})
    id = Wardrik.AgentID.new!("budgeted-#{System.unique_integer([:positive])}", org: "host")
    assert {:ok, _pid} = Wardrik.Fleet.spawn(id, hooks: WardrikPolicy.hooks(policy))

    key = "host/#{id.name}/day"
    assert :ok = WardrikPolicy.Meter.spend(key, 1_000, 10)

    assert {:ok, %WardrikPolicy.Spend{micro_usd: 1_000, tokens: 10}} =
             WardrikPolicy.Meter.read(key)

    assert Enum.any?(
             WardrikStore.keys(WardrikHost.store(), :durable, "meters/"),
             &(&1 =~ id.name)
           )
  end

  test "the triggers' supervisor runs" do
    assert is_pid(Process.whereis(WardrikTrigger.supervisor()))
  end
end

defmodule WardrikHost.GuideTest do
  use ExUnit.Case, async: false

  @moduletag :agents

  defp app(name), do: Module.concat([System.fetch_env!("WARDRIK_HOST_APP") <> name])

  defp user(org),
    do:
      struct!(app(".Accounts.User"),
        id: System.unique_integer([:positive]),
        org: org,
        email: "maria@#{org}.example"
      )

  defp agents, do: app(".Agents")

  setup do
    user = user("acme")
    name = "support-#{System.unique_integer([:positive])}"

    definition = %{
      "model" => "anthropic:claude-sonnet-5",
      "instructions" => "Answer in one sentence."
    }

    assert {:created, _snapshot} = agents().define(user, name, definition)
    %{user: user, agent: Wardrik.AgentID.new!(name, org: "acme", user: to_string(user.id))}
  end

  test "a user defines an agent of their own, and asks it", %{user: user, agent: agent} do
    :ok = Wardrik.Event.Log.subscribe(agent)

    assert {:ok, %{"message" => %{"id" => _id}}} =
             agents().ask(user, agent, "What changed this week?")

    assert_receive %Wardrik.Event.Log.Entry{event: %{"type" => "wardrik.run.started"}}, 10_000
  end

  test "nobody else reaches it, in its org or another", %{agent: agent} do
    for other <- [user("acme"), user("globex")],
        do:
          assert(
            {:error, %Wardrik.Error{type: :not_found}} = agents().ask(other, agent, "Hello?")
          )
  end

  test "the API knows a user by the app's token, and shows them their own agents",
       %{user: user, agent: agent} do
    token = app("Web.Session").token(user)

    assert %{status: 200, body: %{"agents" => listed}} =
             Req.get!("http://127.0.0.1:4850/v1/agents", auth: {:bearer, token}, retry: false)

    assert Enum.any?(listed, &(&1["id"] == to_string(agent)))
    assert %{status: 401} = Req.get!("http://127.0.0.1:4850/v1/agents", retry: false)
  end

  test "a user's agent may name the GitHub server's tools", %{user: user} do
    definition = %{"model" => "anthropic:claude-sonnet-5", "tools" => ["github/*"]}

    assert {:created, _snapshot} =
             agents().define(user, "triage-#{System.unique_integer([:positive])}", definition)
  end

  test "a user's connections offer GitHub, which they have not connected", %{user: user} do
    assert {:ok, %{"connections" => [%{"provider" => "github"} = github]}} =
             agents().connections(user)

    refute Map.has_key?(github, "held_by")
  end

  test "the sign-in callback is the app's own route" do
    endpoint = app("Web.Endpoint")
    conn = Plug.Test.conn(:get, "/oauth/callback/github") |> endpoint.call(endpoint.init([]))
    assert conn.status == 400
  end
end

excluded =
  for part <- [:agents], not WardrikHost.tree?(Atom.to_string(part)), do: part

ExUnit.configure(exclude: excluded)

%{failures: failures} = ExUnit.run()
System.halt(if failures == 0, do: 0, else: 1)
