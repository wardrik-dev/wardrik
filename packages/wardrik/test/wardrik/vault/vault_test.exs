defmodule Wardrik.VaultTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Wardrik.Principal
  alias Wardrik.Vault.Sealed
  alias Wardrik.Vault.Secret
  alias Wardrik.Vault.TestGrants

  defp credential(name, principal),
    do: %Wardrik.Credentials.Request{name: name, principal: principal}

  @jon %Principal{id: "user:jon"}
  @acme %Principal{id: "org:acme"}

  setup context do
    store = Wardrik.Store.ETS.new(name: :"#{context.test}")
    start_supervised!({Wardrik.Store, store})
    key = Wardrik.Vault.generate_key()
    %{store: store, key: key, vault: start_vault(store, [key], {TestGrants, self()})}
  end

  defp start_vault(store, keys, grants) do
    name = :"vault_#{System.unique_integer([:positive])}"
    spec = {Wardrik.Vault, name: name, store: store, keys: keys, grants: grants}
    start_supervised!(Supervisor.child_spec(spec, id: name))
    name
  end

  test "seals a value and unseals it", %{vault: vault, store: store} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "ghp_secret"})

    assert Wardrik.Vault.fetch(vault, @jon, "github") == {:ok, "ghp_secret"}
    refute inspect(%Secret{principal: @jon, name: "github", value: "ghp_secret"}) =~ "ghp_secret"

    scoped = Wardrik.Store.scope(store, "wardrik_vault", format: Sealed)
    assert [path] = Wardrik.Store.keys(scoped)
    assert %Sealed{kind: :secret} = sealed = Wardrik.Store.get(scoped, path)
    refute inspect(sealed) =~ "ghp_secret"
    dumped = Sealed.dump(sealed)
    refute JSON.encode!(dumped) =~ "ghp_secret"
  end

  test "reads a value from the store with its keys, without a running vault", %{
    vault: vault,
    store: store,
    key: key
  } do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "ghp_secret"})

    assert Wardrik.Vault.read(store, @jon, "github", keys: [key]) == {:ok, "ghp_secret"}
    assert Wardrik.Vault.read(store, @acme, "github", keys: [key]) == {:error, :not_found}

    assert Wardrik.Vault.read(store, @jon, "github", keys: [Wardrik.Vault.generate_key()]) ==
             {:error, :undecipherable}
  end

  test "reads an option's secret as the deployment's, as it's read, or takes the value as it is",
       %{
         vault: vault,
         store: store,
         key: key
       } do
    deployment = Wardrik.Vault.deployment()

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: deployment, name: "SIGNING", value: "old"})

    assert Wardrik.Vault.value(vault, {:secret, "SIGNING"}) == {:ok, "old"}
    assert Wardrik.Vault.value(vault, "inline") == {:ok, "inline"}
    assert Wardrik.Vault.value(vault, nil) == {:ok, nil}
    assert {:error, :not_found} = Wardrik.Vault.value(vault, {:secret, "NONE"})

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: deployment, name: "SIGNING", value: "new"})

    assert Wardrik.Vault.value(vault, {:secret, "SIGNING"}) == {:ok, "new"}
    assert Wardrik.Vault.read_value(store, [key], {:secret, "SIGNING"}) == {:ok, "new"}
    assert Wardrik.Vault.read_value(store, [key], "inline") == {:ok, "inline"}

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{
        principal: %Principal{id: "acme"},
        name: "OWN",
        value: "acme's"
      })

    assert {:error, :not_found} = Wardrik.Vault.value(vault, {:secret, "OWN"})
  end

  test "says which vault isn't started" do
    assert_raise ArgumentError, ~r/^MyApp.Missing isn't started/, fn ->
      Wardrik.Vault.fetch(MyApp.Missing, %Wardrik.Principal{id: "user:jon"}, "github")
    end
  end

  test "gives a principal only what it holds", %{vault: vault} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "github", value: "acme's"})

    assert Wardrik.Vault.fetch(vault, @jon, "github") == {:error, :not_found}
  end

  test "reads a value for one purpose only as that kind", %{vault: vault} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "GOOGLE_SECRET", value: "app"},
        kind: :client_secret
      )

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "ANTHROPIC_API_KEY", value: "key"},
        kind: :api_key
      )

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "LOOSE", value: "loose"})

    assert Wardrik.Vault.fetch(vault, @acme, "GOOGLE_SECRET", kind: :api_key) ==
             {:error, :wrong_kind}

    assert Wardrik.Vault.fetch(vault, @acme, "LOOSE", kind: :api_key) == {:error, :wrong_kind}
    assert Wardrik.Vault.fetch(vault, @acme, "ANTHROPIC_API_KEY", kind: :api_key) == {:ok, "key"}

    assert Wardrik.Vault.fetch(vault, @acme, "GOOGLE_SECRET", kind: :client_secret) ==
             {:ok, "app"}

    assert_raise ArgumentError, ~r/:password isn't a vault kind/, fn ->
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "X", value: "x"}, kind: :password)
    end
  end

  test "won't unseal a value relabelled as another kind", %{vault: vault, store: store} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "GOOGLE_SECRET", value: "app"},
        kind: :client_secret
      )

    scoped = Wardrik.Store.scope(store, "wardrik_vault", format: Sealed)
    sealed = Wardrik.Store.get(scoped, "org%3Aacme/GOOGLE_SECRET")

    {:ok, _vsn} =
      Wardrik.Store.put(scoped, "org%3Aacme/GOOGLE_SECRET", %{sealed | kind: :api_key})

    assert Wardrik.Vault.fetch(vault, @acme, "GOOGLE_SECRET", kind: :api_key) ==
             {:error, :undecipherable}
  end

  test "won't unseal a value moved to another principal", %{vault: vault, store: store} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "github", value: "acme's"})

    scoped = Wardrik.Store.scope(store, "wardrik_vault", format: Sealed)

    {:ok, _vsn} =
      Wardrik.Store.put(
        scoped,
        "user%3Ajon/github",
        Wardrik.Store.get(scoped, "org%3Aacme/github")
      )

    assert Wardrik.Vault.fetch(vault, @jon, "github") == {:error, :undecipherable}
  end

  test "seals with the first key and unseals with any", %{vault: vault, store: store, key: old} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{
        principal: @jon,
        name: "github",
        value: "sealed with the old key"
      })

    rotated = start_vault(store, [Wardrik.Vault.generate_key(), old], nil)

    assert Wardrik.Vault.fetch(rotated, @jon, "github") == {:ok, "sealed with the old key"}

    {:ok, _vsn} =
      Wardrik.Vault.put(rotated, %Secret{
        principal: @jon,
        name: "linear",
        value: "sealed with the new key"
      })

    assert Wardrik.Vault.fetch(vault, @jon, "linear") == {:error, :undecipherable}
  end

  test "seals and unseals nothing without a key", %{store: store} do
    {vault, log} = with_log(fn -> start_vault(store, ["not a key"], nil) end)

    assert log =~ "isn't 32 bytes"

    assert Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "x"}) ==
             {:error, :no_key}

    assert Wardrik.Vault.fetch(vault, @jon, "github") == {:error, :no_key}
  end

  test "writes over a version only while it's current", %{vault: vault} do
    {:ok, vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "first"},
        kind: :grant,
        if_vsn: nil
      )

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "second"},
        kind: :grant,
        if_vsn: vsn
      )

    assert {:error, :conflict} =
             Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "third"},
               if_vsn: vsn
             )

    assert {:ok, :grant, "second", _vsn} = Wardrik.Vault.lookup(vault, @jon, "github")
  end

  test "lists names and kinds, and deletes", %{vault: vault} do
    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "a"}, kind: :grant)

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "linear/api", value: "b"})

    {:ok, _vsn} = Wardrik.Vault.put(vault, %Secret{principal: @acme, name: "github", value: "c"})

    listed =
      vault
      |> Wardrik.Vault.list()
      |> Enum.sort()

    assert listed == [
             {"org:acme", "github", :secret},
             {"user:jon", "github", :grant},
             {"user:jon", "linear/api", :secret}
           ]

    assert Wardrik.Vault.names(vault, @jon) == ["github", "linear/api"]
    assert :ok = Wardrik.Vault.delete(vault, @jon, "github")
    assert Wardrik.Vault.names(vault, @jon) == ["linear/api"]
  end

  describe "as an agent's credentials" do
    test "resolves a secret", %{vault: vault} do
      github = credential("github", @jon)

      {:ok, _vsn} =
        Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "ghp_secret"})

      assert Wardrik.Vault.resolve(github, vault) == {:ok, "ghp_secret"}
    end

    test "renews a grant through its grants", %{vault: vault} do
      github = credential("github", @jon)

      {:ok, vsn} =
        Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "token"},
          kind: :grant
        )

      assert Wardrik.Vault.resolve(github, vault) == {:ok, "renewed token"}
      assert_received {:renew, "github", %{value: "token", vsn: ^vsn}}
    end

    test "asks for a name nobody holds", %{vault: vault} do
      github = credential("github", @jon)

      assert Wardrik.Vault.resolve(github, vault) ==
               {:authorize, "https://example.com/authorize/github"}

      assert_received {:ask, "github", "user:jon"}
    end

    test "asks again for a grant it can't unseal", %{vault: vault, store: store} do
      github = credential("github", @jon)

      {:ok, _vsn} =
        Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "token"},
          kind: :grant
        )

      rotated = start_vault(store, [Wardrik.Vault.generate_key()], {TestGrants, self()})

      assert capture_log(fn ->
               assert {:authorize, _url} =
                        Wardrik.Vault.resolve(github, rotated)
             end) =~ "asking again"
    end

    test "tells its grants a grant was refused, and ignores a refused secret", %{vault: vault} do
      github = credential("github", @jon)
      linear = credential("linear", @jon)

      {:ok, _vsn} =
        Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "github", value: "token"},
          kind: :grant
        )

      {:ok, _vsn} =
        Wardrik.Vault.put(vault, %Secret{principal: @jon, name: "linear", value: "secret"})

      assert :ok = Wardrik.Vault.refused(github, vault)
      assert :ok = Wardrik.Vault.refused(linear, vault)
      assert_received {:refused, "github"}
      refute_received {:refused, "linear"}
    end

    test "resolves nothing without a principal, or without grants", %{vault: vault, store: store} do
      unowned = credential("github", nil)
      github = credential("github", @jon)

      assert Wardrik.Vault.resolve(unowned, vault) == {:error, :no_principal}
      assert Wardrik.Vault.refused(unowned, vault) == :ok

      plain = start_vault(store, [Wardrik.Vault.generate_key()], nil)
      assert Wardrik.Vault.resolve(github, plain) == {:error, :not_found}
    end

    test "parks a tool's call on the sign-in its grants ask for", %{vault: vault} do
      context =
        Wardrik.Context.new(
          agent_id: "digest",
          principal: @jon,
          credentials: {Wardrik.Vault, vault}
        )

      assert {:park, %Wardrik.Credentials.Authorization{credential: "github", principal: @jon}} =
               Wardrik.Credentials.fetch(context, "github")
    end
  end
end
