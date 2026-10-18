defmodule Wardrik.CredentialTest do
  use ExUnit.Case, async: true

  alias Wardrik.Credential
  alias Wardrik.Host
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Key
  alias Wardrik.LLM.Request
  alias Wardrik.Run
  alias Wardrik.Test.Calls

  defmodule Vault do
    @moduledoc false
    defstruct []
  end

  defimpl Wardrik.Credentials, for: Vault do
    def resolve(_vault, "github", %Wardrik.Call{run: run}) do
      case Run.agent_id(run).user do
        "jon" ->
          {:ok, Credential.secret("ghs_real", owner: "jon")}

        nil ->
          {:ok, Credential.placeholder("{{org.github}}")}

        user ->
          {:error,
           {:authorization_required, %{url: "https://example.com/connect", code: nil}, user}}
      end
    end

    def resolve(_vault, "explodes", %Wardrik.Call{run: %Run{}}),
      do: raise("the vault is on fire")

    def resolve(_vault, _ref, %Wardrik.Call{run: %Run{}}), do: {:error, :denied}

    def refused(_vault, "explodes", _call), do: raise("the vault is on fire")
    def refused(_vault, ref, %Wardrik.Call{}), do: send(self(), {:refused, ref}) && :ok

    def key(_vault, "XAI_API_KEY"), do: {:ok, "sk-from-the-vault"}
    def key(_vault, _name), do: :error
  end

  defp run(opts \\ []) do
    {user, opts} = Keyword.pop(opts, :user)
    {credentials, opts} = Keyword.pop(opts, :credentials, %Wardrik.Credentials.None{})
    id = Wardrik.AgentID.new!("assistant", org: "acme", user: user)
    Run.root(Config.new(), id, [host: Host.new(credentials: credentials)] ++ opts)
  end

  describe "resolve/2" do
    test "asks the credentials of the run's host, which see who the work is for" do
      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, run(credentials: %Vault{}, user: "jon")),
                 "github"
               )

      assert credential.kind == :secret
      assert credential.owner == "jon"
      assert Credential.reveal(credential) == "ghs_real"
    end

    test "a user who has not connected is told where to, and whose the credential will be" do
      assert {:error, {:authorization_required, %{url: "https://example.com/connect"}, "someone"}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, run(credentials: %Vault{}, user: "someone")),
                 "github"
               )
    end

    test "a credential can resolve to a placeholder for a proxy to exchange" do
      assert {:ok, %Credential{kind: :placeholder, value: "{{org.github}}"}} =
               Credential.resolve(Calls.tool("tool", %{}, run(credentials: %Vault{})), "github")
    end

    test "a name the resolver refuses is an error, not a raise" do
      assert {:error, :denied} =
               Credential.resolve(
                 Calls.tool("tool", %{}, run(credentials: %Vault{})),
                 "anything"
               )
    end

    test "a resolver that raises fails the call, not the turn" do
      assert {:error, {:resolver_failed, message}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, run(credentials: %Vault{})),
                 "explodes"
               )

      assert message =~ "the vault is on fire"
    end

    test "a host with no credentials resolves nothing" do
      assert {:error, :no_resolver} =
               Credential.resolve(Calls.tool("tool", %{}, run()), "github")
    end
  end

  describe "refused/2" do
    test "tells the credentials of the run's host which credential was refused" do
      call = Calls.tool("github__read", %{}, run(user: "jon", credentials: %Vault{}))

      assert :ok = Credential.refused(call, "github")
      assert_received {:refused, "github"}
    end

    test "passes over credentials that raise, and a host with none" do
      assert :ok =
               Credential.refused(
                 Calls.tool("t", %{}, run(credentials: %Vault{})),
                 "explodes"
               )

      assert :ok = Credential.refused(Calls.tool("t", %{}, run()), "x")
    end
  end

  describe "keeping the value out of sight" do
    test "inspect says nothing" do
      inspected = inspect(Credential.secret("ghs_real"))

      refute inspected =~ "ghs_real"
      assert inspected == "#Wardrik.Credential<secret, redacted>"
    end

    test "a credential inside something else is redacted too" do
      refute inspect(%{token: Credential.secret("ghs_real")}) =~ "ghs_real"
    end

    test "reveal/1 is the one way out" do
      assert Credential.reveal(Credential.secret("ghs_real")) == "ghs_real"
    end
  end

  describe "how long a credential lasts" do
    test "one with no expiry lasts as long as anything holds it" do
      assert Credential.remaining_ms(Credential.secret("s")) == :infinity
    end

    test "one with an expiry counts down to it" do
      at = System.system_time(:second) + 60

      remaining = Credential.remaining_ms(Credential.secret("s", expires_at: at))

      assert remaining > 55_000
      assert remaining <= 60_000
    end

    test "one that has expired has nothing left, rather than less than nothing" do
      at = System.system_time(:second) - 60

      assert Credential.remaining_ms(Credential.secret("s", expires_at: at)) == 0
    end

    test "a placeholder carries one the same way" do
      at = System.system_time(:second) + 60

      assert %Credential{kind: :placeholder, expires_at: ^at} =
               Credential.placeholder("{{x}}", expires_at: at)
    end
  end

  test "credentials are the host's, set once for every agent, and no agent's own" do
    refute :credentials in Run.seams()
    assert run(credentials: %Vault{}).host.credentials == %Vault{}
  end

  describe "a model provider's key" do
    test "rides a request that has none, from the host's credentials" do
      request = request("xai:grok-4")
      host = Host.new(credentials: %Vault{})

      assert Key.put(request, host).opts[:api_key] == "sk-from-the-vault"
    end

    test "leaves one the request carries, and asks nothing where none is held" do
      host = Host.new(credentials: %Vault{})
      dispatched = Request.put_opts(request("xai:grok-4"), api_key: "sk-dispatched")

      assert Key.put(dispatched, host).opts[:api_key] == "sk-dispatched"

      configured = request("zai:glm-4.6")
      assert Key.put(configured, host) == configured

      unheld = request("groq:llama-3.3-70b-versatile")
      assert Key.put(unheld, host) == unheld
    end
  end

  defp request(model),
    do: Request.new(Config.new(model_spec: model), ReqLLM.Context.new([]))
end
