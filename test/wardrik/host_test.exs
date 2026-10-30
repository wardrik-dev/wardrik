defmodule Wardrik.HostTest do
  use ExUnit.Case, async: true

  test "builds a Postgres store" do
    wardrik =
      Wardrik.new(
        name: MyApp.AgentRuntime,
        store: {WardrikStore.Ecto, url: "postgres://localhost/x"},
        discovery_interval_ms: 5_000
      )

    assert %Wardrik{store: %WardrikStore{adapter: WardrikStore.Ecto}} = wardrik
    assert {WardrikStore.Durable, opts} = wardrik.backend
    assert opts[:discovery_interval_ms] == 5_000

    assert %Wardrik{store: %WardrikStore{adapter: WardrikStore.Ecto, config: MyApp.Repo}} =
             Wardrik.new(name: MyApp.AgentRuntime, store: {WardrikStore.Ecto, repo: MyApp.Repo})
  end

  test "names a principal, and the key a model's calls take" do
    assert %WardrikCore.Principal{id: "acme/@maria", attributes: %{name: "Maria"}} =
             Wardrik.principal("acme/@maria", %{name: "Maria"})

    assert Wardrik.principal("acme").attributes == %{}
    assert Wardrik.key_name("zai_coding_plan:glm-5.1") == "ZAI_API_KEY"
  end

  test "writes positions as a cursor, and reads them back" do
    cursor = Wardrik.cursor(%{"acme/triage" => 41})
    assert Wardrik.positions(cursor) == {:ok, %{"acme/triage" => 41}}
    assert Wardrik.positions("not a cursor") == :error
  end

  test "says what a policy would refuse" do
    assert Wardrik.check_policy(%{"ask" => ["publish"]}) == :ok

    assert Wardrik.check_policy(%{"judge" => %{"questions" => [%{"question" => "Publish?"}]}}) ==
             {:error, "a question decides nothing; give it deny, ask or allow"}
  end

  test "gives Plug.Parsers the body reader that keeps a webhook's body as it came" do
    assert Wardrik.HTTP.body_reader() == {WardrikHTTP.BodyReader, :read_body, []}
  end
end
