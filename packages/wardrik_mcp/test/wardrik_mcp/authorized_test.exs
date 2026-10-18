defmodule WardrikMCP.AuthorizedTest do
  @moduledoc """
  The whole chain, with only the authorization server stubbed: an agent calls a
  tool on a server it is not authorized for, the turn parks on a link, the
  person follows it, and approving the parked call runs it with the token.
  """

  use WardrikMCP.Test.Case, async: false
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.Call

  @moduletag server_opts: [credential: "github", credential_env: "DEMO_TOKEN"]

  setup %{key: key, owner: owner} do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    stub_server(cimd: true)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])
    start_supervised!({WardrikOAuth.Supervisor, oauth: oauth(), loopback: false})

    run =
      Wardrik.Test.run(
        tools: [{WardrikMCP, key}],
        id: Wardrik.AgentID.parse!("acme/@#{owner}/assistant"),
        host: host()
      )

    %{run: run}
  end

  defp secret(key, run),
    do: Wardrik.Test.call(run, "#{key.name}__secret", %{"name" => "DEMO_TOKEN"})

  test "parks on a link, then runs once the user has followed it", context do
    %{key: key, run: run, owner: owner} = context

    assert %Call{state: :waiting, asks: [%{prompt: prompt, link: %{url: url}}]} =
             call = secret(key, run)

    assert url =~ "https://auth.example.com/authorize"
    refute prompt =~ "https://"

    assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")
    assert WardrikOAuth.connected?(vault(), "github", {"acme", owner})

    assert %Call{state: :done, result: {:ok, %{"result" => %{"content" => content}}}} =
             Wardrik.Test.resume(run, call)

    assert content =~ "at_first"
  end

  test "the token the server sees is the one the flow produced", context do
    %{key: key, run: run} = context

    %Call{asks: [%{link: %{url: url}}]} = call = secret(key, run)
    {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert %Call{result: {:ok, %{"result" => %{"content" => content}}}} =
             Wardrik.Test.resume(run, call)

    refute content =~ "rt_first"
  end
end
