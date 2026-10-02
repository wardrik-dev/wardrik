defmodule WardrikOAuthTest do
  use WardrikOAuth.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls

  setup do
    start_supervised!({WardrikOAuth.Supervisor, loopback: false})

    :ok
  end

  defp scope(owner),
    do: Config.new() |> Scope.root("acme/@#{owner}/a", user: owner, credentials: WardrikVault)

  defp connect(owner, opts \\ []) do
    stub_server(Keyword.merge([cimd: true], opts))
    configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

    {:error, {:authorization_required, url}} =
      Credential.resolve(Calls.tool("tool", %{}, scope(owner)), "github")

    url
  end

  describe "who a token belongs to" do
    defp in_org(org, nil),
      do: Config.new() |> Scope.root("#{org}/a", org: org, credentials: WardrikVault)

    defp in_org(org, user),
      do:
        Config.new()
        |> Scope.root("#{org}/@#{user}/a", org: org, user: user, credentials: WardrikVault)

    defp resolve_in(scope, ref), do: Credential.resolve(Calls.tool("tool", %{}, scope), ref)

    test "a user's is kept for their org and them together", %{owner: owner} do
      stub_server(cimd: true)
      configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

      {:error, {:authorization_required, url}} =
        resolve_in(in_org("acme", owner), "github")

      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert {:ok, _credential} = resolve_in(in_org("acme", owner), "github")
      assert WardrikOAuth.connected?("github", {"acme", owner})

      assert {:error, {:authorization_required, _url}} =
               resolve_in(in_org("globex", owner), "github")
    end

    test "an org's is asked of an agent with no user, and its users are asked for their own",
         %{owner: owner} do
      stub_server(cimd: true)
      configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])
      org = "org-#{owner}"

      {:error, {:authorization_required, url}} = resolve_in(in_org(org, nil), "github")
      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert {:ok, credential} = resolve_in(in_org(org, nil), "github")
      assert credential.owner == org
      assert WardrikOAuth.connected?("github", org)

      assert {:error, {:authorization_required, _url}} = resolve_in(in_org(org, owner), "github")
      refute WardrikOAuth.connected?("github", {org, owner})
    end

    test "calls that park at once share one flow", %{owner: owner} do
      stub_server(cimd: true)
      configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])

      urls =
        1..4
        |> Enum.map(fn _n ->
          Task.async(fn -> resolve_in(scope(owner), "github") end)
        end)
        |> Task.await_many()
        |> Enum.map(fn {:error, {:authorization_required, url}} -> url end)
        |> Enum.uniq()

      assert [_one] = urls
    end
  end

  describe "a flow under way" do
    alias WardrikOAuth.Pending

    test "cannot be finished by a callback once it has expired", %{owner: owner} do
      url = connect(owner)
      {:ok, flight} = Pending.under_way("github", {nil, owner})
      Pending.drop(flight.state)
      {:ok, _url} = Pending.start(%{flight | started_at: flight.started_at - :timer.hours(1)})

      assert {:error, :no_such_flow} = WardrikOAuth.finish(state_of(url), "the-code")
    end

    test "of the device grant is not finished by a callback", %{owner: owner} do
      stub_server(cimd: true, device: %{"expires_in" => 900, "interval" => 60})

      configure(providers: [github: [resource: resource(), scopes: ~w(repo), flow: :device]])

      {:error, {:authorization_required, _url, _code}} =
        Credential.resolve(Calls.tool("tool", %{}, scope(owner)), "github")

      {:ok, flight} = Pending.under_way("github", {nil, owner})

      assert {:error, :no_such_flow} = WardrikOAuth.finish(flight.state, "a-code")
      assert {:ok, _still} = Pending.under_way("github", {nil, owner})
    end

    test "on another node is joined there, and dropped with the rest", %{owner: owner} do
      url = connect(owner)
      resume = {Wardrik.Agent, :decide, ["acme/@x/a", %{"call_9" => :approve}, []]}

      # This node stands in for the others: the flow is found by asking.
      assert {:ok, flight} = Pending.under_way_on([node()], "github", {nil, owner}, resume)
      assert flight.url == url
      assert resume in flight.resumes

      assert :error = Pending.under_way_on([node()], "github", {nil, "nobody"}, nil)
      assert :error = Pending.under_way_on([:nowhere@nohost], "github", {nil, owner}, nil)

      :ok = Pending.drop_on([node()], "github", {nil, owner})
      assert :error = Pending.under_way("github", {nil, owner})
    end

    test "for a user and provider are dropped together", %{owner: owner} do
      connect(owner)
      :ok = Pending.drop("github", {nil, owner})
      assert :error = Pending.under_way("github", {nil, owner})
    end

    test "says what it is for, never its verifier or client", %{owner: owner} do
      connect(owner)
      {:ok, flight} = Pending.under_way("github", {nil, owner})

      shown = inspect(flight)
      assert shown =~ owner
      refute shown =~ flight.verifier
      refute shown =~ flight.state
    end
  end

  test "a provider's authorization params go with the user to the server", %{owner: owner} do
    stub_server(cimd: true)

    configure(
      providers: [
        github: [
          resource: resource(),
          authorization_params: [access_type: "offline", prompt: :consent]
        ]
      ]
    )

    {:error, {:authorization_required, url}} =
      Credential.resolve(Calls.tool("tool", %{}, scope(owner)), "github")

    assert %{"access_type" => "offline", "prompt" => "consent"} = params_of(url)
  end

  test "a provider's authorization params cannot set what the flow sets itself" do
    assert_raise ArgumentError, ~r/cannot set redirect_uri, which the flow sets itself/, fn ->
      WardrikOAuth.Provider.new(:github,
        resource: resource(),
        authorization_params: %{"redirect_uri" => "https://elsewhere.example"}
      )
    end
  end

  test "a provider says what it is, never its client secret" do
    provider =
      WardrikOAuth.Provider.new(:github, resource: resource(), client_secret: "s3cret-value")

    refute inspect(provider) =~ "s3cret-value"
  end

  describe "scopes" do
    test "are the resource's where the provider names none, and none where neither does",
         %{owner: owner} do
      stub_server(cimd: true, resource_scopes: ["read", "write"])
      configure(providers: [github: [resource: resource()]])

      {:error, {:authorization_required, url}} =
        Credential.resolve(Calls.tool("tool", %{}, scope(owner)), "github")

      assert params_of(url)["scope"] == "read write"

      other = owner <> "-other"
      stub_server(cimd: true)

      {:error, {:authorization_required, url}} =
        Credential.resolve(Calls.tool("tool", %{}, scope(other)), "github")

      refute Map.has_key?(params_of(url), "scope")
    end
  end

  describe "a user who has not authorized" do
    test "is sent somewhere, and the turn can park on it", %{owner: owner} do
      url = connect(owner)

      assert String.starts_with?(url, "https://auth.example.com/authorize?")
      assert params_of(url)["client_id"] == "https://wardrik.dev/oauth/client"
    end

    test "is offered the same link while the flow is still under way", %{owner: owner} do
      url = connect(owner)

      assert {:error, {:authorization_required, ^url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )
    end

    test "gets a link of their own, not somebody else's", %{owner: owner} do
      mine = connect(owner)

      {:error, {:authorization_required, theirs}} =
        Credential.resolve(
          Calls.tool("tool", %{}, scope("someone-else")),
          "github"
        )

      refute state_of(mine) == state_of(theirs)
    end
  end

  describe "finishing the flow" do
    test "writes the token down, and the next call resolves it", %{owner: owner} do
      url = connect(owner)

      assert {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )

      assert Credential.reveal(credential) == "at_first"
      assert WardrikOAuth.connected?("github", {nil, owner})
    end

    test "the credential says when it stops being good", %{owner: owner} do
      url = connect(owner)
      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )

      assert credential.expires_at > System.system_time(:second)
      assert Credential.remaining_ms(credential) > 0
    end

    test "the token is sealed in the vault, not written in the clear", %{owner: owner} do
      url = connect(owner)
      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      path = WardrikVault.path("github", {nil, owner})
      {sealed, _vsn} = Wardrik.Store.lookup(WardrikVault.namespace(), path)

      refute inspect(sealed) =~ "at_first"
    end

    test "a callback nobody started is refused", %{owner: _owner} do
      configure(providers: [github: [resource: resource()]])

      assert {:error, :no_such_flow} = WardrikOAuth.finish("made-up", "the-code")
    end

    test "a state can only be claimed once", %{owner: owner} do
      url = connect(owner)
      state = state_of(url)

      assert {:ok, "github"} = WardrikOAuth.finish(state, "the-code")
      assert {:error, :no_such_flow} = WardrikOAuth.finish(state, "the-code")
    end
  end

  describe "a token that has expired" do
    setup %{owner: owner} do
      url =
        connect(owner,
          token: %{"access_token" => "at_first", "refresh_token" => "rt_first", "expires_in" => 1}
        )

      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")
      flush()

      :ok
    end

    test "is renewed without asking the user again", %{owner: owner} do
      stub_server(cimd: true, token: %{"access_token" => "at_second", "expires_in" => 3600})

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )

      assert Credential.reveal(credential) == "at_second"

      assert_receive {:oauth, "POST", "/token", body}
      assert URI.decode_query(body)["grant_type"] == "refresh_token"
    end

    test "the renewed token is what is stored from then on", %{owner: owner} do
      stub_server(cimd: true, token: %{"access_token" => "at_second", "expires_in" => 3600})

      {:ok, _credential} =
        Credential.resolve(Calls.tool("tool", %{}, scope(owner)), "github")

      stub_server(cimd: true, token: %{"error" => "server_is_down"})

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )

      assert Credential.reveal(credential) == "at_second"
    end

    test "sends the user back where it cannot be renewed", %{owner: owner} do
      stub_server(cimd: true, token: %{"error" => "invalid_grant"})

      assert {:error, {:authorization_required, _url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )
    end
  end

  describe "opening the link" do
    test "is left to the deployment where the callback answers elsewhere", %{owner: owner} do
      # The case configures a redirect URI of its own, so this is not loopback.
      connect(owner)

      refute_receive {:browser, _url}
    end

    test "is off when the deployment says so", %{owner: owner} do
      stub_server(cimd: true)

      configure(
        providers: [github: [resource: resource(), scopes: ~w(repo)]],
        redirect: [open: false]
      )

      assert {:error, {:authorization_required, _url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )
    end

    test "opens the link where the callback comes back to this machine", %{owner: owner} do
      stub_server(cimd: true)

      configure(
        providers: [github: [resource: resource(), scopes: ~w(repo)]],
        redirect: [port: 4599, opener: "true"]
      )

      assert {:error, {:authorization_required, url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )

      assert params_of(url)["redirect_uri"] == "http://127.0.0.1:4599/callback/github"
    end

    test "a machine with nothing to open a link with says so, and the flow stands" do
      Application.put_env(:wardrik_oauth, WardrikOAuth,
        redirect: [opener: "no-such-browser-command"]
      )

      assert {:error, :no_browser} = WardrikOAuth.Browser.open("https://example.com")
    end
  end

  describe "a token nothing can read" do
    test "sends the user back to authorize, and forgets what it could not read", %{owner: owner} do
      url = connect(owner)
      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      # The key it was sealed with, rotated away without it.
      Application.put_env(:wardrik_vault, WardrikVault,
        keys: [WardrikVault.generate_key()],
        grants: WardrikOAuth
      )

      assert {:error, {:authorization_required, _url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )

      refute WardrikOAuth.connected?("github", {nil, owner})
    end

    test "so does something that is not a token at all", %{owner: owner} do
      configure(providers: [github: [resource: resource(), scopes: ~w(repo)]])
      stub_server(cimd: true)
      :ok = WardrikVault.put("github", {nil, owner}, "not json", kind: :grant)

      assert {:error, {:authorization_required, _url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )
    end
  end

  describe "the rest of the resolver" do
    test "a provider nobody configured is not a crash", %{owner: owner} do
      configure(providers: [])

      assert {:error, :not_found} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "unknown"
               )
    end

    test "a scope with no user and no org asks the deployment" do
      stub_server(cimd: true)
      configure(providers: [github: [resource: resource()]])
      scope = Config.new() |> Scope.root("acme/a", credentials: WardrikVault)

      assert {:error, {:authorization_required, url}} =
               Credential.resolve(Calls.tool("tool", %{}, scope), "github")

      assert {:ok, %{owner: nil}} = WardrikOAuth.Pending.claim(state_of(url))
    end

    test "disconnecting means the next call asks again", %{owner: owner} do
      url = connect(owner)
      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert :ok = WardrikOAuth.disconnect("github", {nil, owner})
      refute WardrikOAuth.connected?("github", {nil, owner})

      assert {:error, {:authorization_required, _url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 "github"
               )
    end

    test "connections/1 says what a user could authorize and what they have", %{owner: owner} do
      url = connect(owner)
      {:ok, "github"} = WardrikOAuth.finish(state_of(url), "the-code")

      assert WardrikOAuth.connections({nil, owner}) == [%{provider: "github", connected?: true}]
      assert WardrikOAuth.connections("nobody") == [%{provider: "github", connected?: false}]
    end
  end
end
