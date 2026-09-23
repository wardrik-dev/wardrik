defmodule TarsMCP.AuthorizedTest do
  @moduledoc """
  The whole chain, with only the authorization server stubbed: an agent calls a
  tool on a server it is not authorized for, the turn parks on a link, the
  person follows it, and approving the parked call runs it with the token.
  """

  use TarsMCP.Case, async: false
  use TarsOAuth.Case, async: false

  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner
  alias Tars.Scope

  @moduletag server_opts: [credential: {:user, "github"}, credential_env: "DEMO_TOKEN"]

  setup %{ref: ref, owner: owner} do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    start_supervised!({TarsOAuth.Supervisor, loopback: false})
    stub_server(cimd: true)
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

    scope =
      Config.new(tools: [{TarsMCP, ref}])
      |> Scope.root("acme/#{owner}/assistant", user: owner, credentials: TarsOAuth)

    %{scope: scope}
  end

  defp call(ref, scope, tool, arguments) do
    ToolRunner.execute(%{id: "call_1", name: "#{ref}__#{tool}", arguments: arguments}, scope)
  end

  test "parks on a link, then runs once the user has followed it", context do
    %{ref: ref, scope: scope, owner: owner} = context

    assert {:parked, call, prompt} = call(ref, scope, "secret", %{"name" => "DEMO_TOKEN"})
    assert prompt =~ "https://auth.example.com/authorize"

    assert {:ok, "github"} = TarsOAuth.finish(state_in(prompt), "the-code")
    assert TarsOAuth.connected?("github", owner)

    assert {:settled, ^call, message} = ToolRunner.execute(call, scope, authorize: false)

    [part] = message.content
    assert part.text =~ "at_first"
  end

  test "the token the server sees is the one the flow produced", context do
    %{ref: ref, scope: scope} = context

    {:parked, call, prompt} = call(ref, scope, "secret", %{"name" => "DEMO_TOKEN"})
    {:ok, "github"} = TarsOAuth.finish(state_in(prompt), "the-code")

    {:settled, ^call, message} = ToolRunner.execute(call, scope, authorize: false)

    [part] = message.content
    refute part.text =~ "rt_first"
  end

  defp state_in(prompt) do
    ~r{https://\S+} |> Regex.run(prompt) |> hd() |> state_of()
  end
end
