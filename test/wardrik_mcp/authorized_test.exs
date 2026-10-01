defmodule WardrikMCP.AuthorizedTest do
  @moduledoc """
  The whole chain, with only the authorization server stubbed: an agent calls a
  tool on a server it is not authorized for, the turn parks on a link, the
  person follows it, and approving the parked call runs it with the token.
  """

  use WardrikMCP.Case, async: false
  use WardrikOAuth.Case, async: false

  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope

  @moduletag server_opts: [credential: {:user, "github"}, credential_env: "DEMO_TOKEN"]

  setup %{ref: ref, owner: owner} do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    start_supervised!({WardrikOAuth.Supervisor, loopback: false})
    stub_server(cimd: true)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

    scope =
      Config.new(tools: [{WardrikMCP, ref}])
      |> Scope.root("acme/@#{owner}/assistant", user: owner, credentials: WardrikOAuth)

    %{scope: scope}
  end

  defp call(ref, scope, tool, arguments) do
    ToolRunner.execute(%{id: "call_1", name: "#{ref}__#{tool}", arguments: arguments}, scope)
  end

  test "parks on a link, then runs once the user has followed it", context do
    %{ref: ref, scope: scope, owner: owner} = context

    assert %Wardrik.Call{state: :waiting, asks: [%{prompt: prompt, link: %{url: url}}]} =
             call =
             call(ref, scope, "secret", %{"name" => "DEMO_TOKEN"})

    assert url =~ "https://auth.example.com/authorize"
    refute prompt =~ "https://"

    assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")
    assert WardrikOAuth.connected?("github", {nil, owner})

    [message] =
      call
      |> Wardrik.Call.approve()
      |> ToolRunner.execute(scope)
      |> List.wrap()
      |> ToolRunner.messages()

    [part] = message.content
    assert part.text =~ "at_first"
  end

  test "the token the server sees is the one the flow produced", context do
    %{ref: ref, scope: scope} = context

    %Wardrik.Call{asks: [%{link: %{url: url}}]} =
      call = call(ref, scope, "secret", %{"name" => "DEMO_TOKEN"})

    {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

    [message] =
      call
      |> Wardrik.Call.approve()
      |> ToolRunner.execute(scope)
      |> List.wrap()
      |> ToolRunner.messages()

    [part] = message.content
    refute part.text =~ "rt_first"
  end
end
