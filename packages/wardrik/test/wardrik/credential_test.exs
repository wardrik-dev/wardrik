defmodule Wardrik.CredentialTest do
  use ExUnit.Case, async: true

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls

  defmodule Vault do
    @moduledoc false
    @behaviour Wardrik.Credential

    @impl true
    def resolve("github", %Wardrik.Call{scope: %Scope{user: "jon"}}),
      do: {:ok, Credential.secret("ghs_real", owner: "jon")}

    def resolve("github", %Wardrik.Call{scope: %Scope{user: nil}}),
      do: {:ok, Credential.placeholder("{{org.github}}")}

    def resolve("github", %Wardrik.Call{scope: %Scope{user: user}}),
      do:
        {:error,
         {:authorization_required, %{url: "https://example.com/connect", code: nil}, user}}

    def resolve("explodes", %Wardrik.Call{scope: %Scope{}}),
      do: raise("the vault is on fire")

    def resolve(_ref, %Wardrik.Call{scope: %Scope{}}), do: {:error, :denied}

    @impl true
    def refused("explodes", _call), do: raise("the vault is on fire")
    def refused(ref, %Wardrik.Call{}), do: send(self(), {:refused, ref}) && :ok
  end

  defmodule Plain do
    @moduledoc false
    @behaviour Wardrik.Credential

    @impl true
    def resolve(_ref, _call), do: {:error, :denied}
  end

  defp scope(opts \\ []) do
    Config.new() |> Scope.root("acme/@jon/assistant", opts)
  end

  describe "resolve/2" do
    test "asks the scope's resolver, which sees who the work is for" do
      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault, user: "jon")),
                 "github"
               )

      assert credential.kind == :secret
      assert credential.owner == "jon"
      assert Credential.reveal(credential) == "ghs_real"
    end

    test "a user who has not connected is told where to, and whose the credential will be" do
      assert {:error, {:authorization_required, %{url: "https://example.com/connect"}, "someone"}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault, user: "someone")),
                 "github"
               )
    end

    test "a credential can resolve to a placeholder for a proxy to exchange" do
      assert {:ok, %Credential{kind: :placeholder, value: "{{org.github}}"}} =
               Credential.resolve(Calls.tool("tool", %{}, scope(credentials: Vault)), "github")
    end

    test "a name the resolver refuses is an error, not a raise" do
      assert {:error, :denied} =
               Credential.resolve(Calls.tool("tool", %{}, scope(credentials: Vault)), "anything")
    end

    test "a resolver that raises fails the call, not the turn" do
      assert {:error, {:resolver_failed, message}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault)),
                 "explodes"
               )

      assert message =~ "the vault is on fire"
    end

    test "a scope with no resolver resolves nothing" do
      assert {:error, :no_resolver} =
               Credential.resolve(Calls.tool("tool", %{}, scope()), "github")
    end
  end

  describe "refused/2" do
    test "tells the scope's resolver which credential was refused" do
      call = Calls.tool("github__read", %{}, scope(user: "jon", credentials: Vault))

      assert :ok = Credential.refused(call, "github")
      assert_received {:refused, "github"}
    end

    test "passes over a resolver without it, one that raises, and a scope with none" do
      assert :ok =
               Credential.refused(Calls.tool("t", %{}, scope(credentials: Plain)), "x")

      assert :ok =
               Credential.refused(
                 Calls.tool("t", %{}, scope(credentials: Vault)),
                 "explodes"
               )

      assert :ok = Credential.refused(Calls.tool("t", %{}, scope()), "x")
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

  test "credentials/1 is a scope seam a host sets once" do
    assert :credentials in Scope.seams()
    assert scope(credentials: Vault).credentials == Vault
  end
end
