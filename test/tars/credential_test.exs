defmodule Tars.CredentialTest do
  use ExUnit.Case, async: true

  alias Tars.Credential
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.Calls

  defmodule Vault do
    @moduledoc false
    @behaviour Tars.Credential

    @impl true
    def resolve({:user, "github"}, %Tars.Call{scope: %Scope{user: "jon"}}),
      do: {:ok, Credential.secret("ghs_real")}

    def resolve({:user, "github"}, %Tars.Call{scope: %Scope{}}),
      do: {:error, {:authorization_required, "https://example.com/connect"}}

    def resolve({:org, "github"}, %Tars.Call{scope: %Scope{}}),
      do: {:ok, Credential.placeholder("{{org.github}}")}

    def resolve({:named, "explodes"}, %Tars.Call{scope: %Scope{}}),
      do: raise("the vault is on fire")

    def resolve(_ref, %Tars.Call{scope: %Scope{}}), do: {:error, :denied}
  end

  defp scope(opts \\ []) do
    Config.new() |> Scope.root("acme/jon/assistant", opts)
  end

  describe "resolve/2" do
    test "asks the scope's resolver, which sees who the work is for" do
      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault, user: "jon")),
                 {:user, "github"}
               )

      assert credential.kind == :secret
      assert Credential.reveal(credential) == "ghs_real"
    end

    test "a user who has not connected is told where to" do
      assert {:error, {:authorization_required, "https://example.com/connect"}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault, user: "someone")),
                 {:user, "github"}
               )
    end

    test "an org reference can resolve to a placeholder for a proxy to exchange" do
      assert {:ok, %Credential{kind: :placeholder, value: "{{org.github}}"}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault)),
                 {:org, "github"}
               )
    end

    test "a reference the resolver refuses is an error, not a raise" do
      assert {:error, :denied} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault)),
                 {:named, "anything"}
               )
    end

    test "a resolver that raises fails the call, not the turn" do
      assert {:error, {:resolver_failed, message}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: Vault)),
                 {:named, "explodes"}
               )

      assert message =~ "the vault is on fire"
    end

    test "a scope with no resolver resolves nothing" do
      assert {:error, :no_resolver} =
               Credential.resolve(Calls.tool("tool", %{}, scope()), {:user, "github"})
    end
  end

  describe "keeping the value out of sight" do
    test "inspect says nothing" do
      inspected = inspect(Credential.secret("ghs_real"))

      refute inspected =~ "ghs_real"
      assert inspected == "#Tars.Credential<secret, redacted>"
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
