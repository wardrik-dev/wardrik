defmodule WardrikVaultTest do
  use ExUnit.Case, async: true

  defp credential(name, principal),
    do: %WardrikCore.Credentials.Request{name: name, principal: principal}

  import ExUnit.CaptureLog

  alias WardrikCore.Principal
  alias WardrikVault.Sealed
  alias WardrikVault.Secret
  alias WardrikVault.TestGrants

  @jon %Principal{id: "user:jon"}
  @acme %Principal{id: "org:acme"}

  setup context do
    store = WardrikStore.ETS.new(name: :"#{context.test}")
    start_supervised!({WardrikStore, store})
    key = WardrikVault.generate_key()
    %{store: store, key: key, vault: start_vault(store, [key], {TestGrants, self()})}
  end

  defp start_vault(store, keys, grants) do
    name = :"vault_#{System.unique_integer([:positive])}"
    spec = {WardrikVault, name: name, store: store, keys: keys, grants: grants}
    start_supervised!(Supervisor.child_spec(spec, id: name))
    name
  end

  test "seals a value and unseals it", %{vault: vault, store: store} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "ghp_secret"})

    assert WardrikVault.fetch(vault, @jon, "github") == {:ok, "ghp_secret"}
    refute inspect(%Secret{principal: @jon, name: "github", value: "ghp_secret"}) =~ "ghp_secret"

    scoped = WardrikStore.scope(store, "wardrik_vault")
    assert [path] = WardrikStore.keys(scoped)
    assert %Sealed{} = sealed = WardrikStore.get(scoped, path)
    refute inspect(sealed) =~ "ghp_secret"
    refute :erlang.term_to_binary(sealed) =~ "ghp_secret"
  end

  test "reads a value from the store with its keys, without a running vault", %{
    vault: vault,
    store: store,
    key: key
  } do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "ghp_secret"})

    assert WardrikVault.read(store, @jon, "github", keys: [key]) == {:ok, "ghp_secret"}
    assert WardrikVault.read(store, @acme, "github", keys: [key]) == {:error, :not_found}

    assert WardrikVault.read(store, @jon, "github", keys: [WardrikVault.generate_key()]) ==
             {:error, :undecipherable}
  end

  test "reads an option's secret as the deployment's, as it's read, or takes the value as it is",
       %{
         vault: vault,
         store: store,
         key: key
       } do
    deployment = WardrikVault.deployment()

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: deployment, name: "SIGNING", value: "old"})

    assert WardrikVault.value(vault, {:secret, "SIGNING"}) == {:ok, "old"}
    assert WardrikVault.value(vault, "inline") == {:ok, "inline"}
    assert WardrikVault.value(vault, nil) == {:ok, nil}
    assert {:error, :not_found} = WardrikVault.value(vault, {:secret, "NONE"})

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: deployment, name: "SIGNING", value: "new"})

    assert WardrikVault.value(vault, {:secret, "SIGNING"}) == {:ok, "new"}
    assert WardrikVault.read_value(store, [key], {:secret, "SIGNING"}) == {:ok, "new"}
    assert WardrikVault.read_value(store, [key], "inline") == {:ok, "inline"}

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{
        principal: %Principal{id: "acme"},
        name: "OWN",
        value: "acme's"
      })

    assert {:error, :not_found} = WardrikVault.value(vault, {:secret, "OWN"})
  end

  test "says which vault isn't started" do
    assert_raise ArgumentError, ~r/^MyApp.Missing isn't started/, fn ->
      WardrikVault.fetch(MyApp.Missing, %WardrikCore.Principal{id: "user:jon"}, "github")
    end
  end

  test "gives a principal only what it holds", %{vault: vault} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @acme, name: "github", value: "acme's"})

    assert WardrikVault.fetch(vault, @jon, "github") == {:error, :not_found}
  end

  test "reads a value for one purpose only as that kind", %{vault: vault} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @acme, name: "GOOGLE_SECRET", value: "app"},
        kind: :client_secret
      )

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @acme, name: "ANTHROPIC_API_KEY", value: "key"},
        kind: :api_key
      )

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @acme, name: "LOOSE", value: "loose"})

    assert WardrikVault.fetch(vault, @acme, "GOOGLE_SECRET", kind: :api_key) ==
             {:error, :wrong_kind}

    assert WardrikVault.fetch(vault, @acme, "LOOSE", kind: :api_key) == {:error, :wrong_kind}
    assert WardrikVault.fetch(vault, @acme, "ANTHROPIC_API_KEY", kind: :api_key) == {:ok, "key"}
    assert WardrikVault.fetch(vault, @acme, "GOOGLE_SECRET", kind: :client_secret) == {:ok, "app"}

    assert_raise ArgumentError, ~r/:password isn't a vault kind/, fn ->
      WardrikVault.put(vault, %Secret{principal: @acme, name: "X", value: "x"}, kind: :password)
    end
  end

  test "won't unseal a value relabelled as another kind", %{vault: vault, store: store} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @acme, name: "GOOGLE_SECRET", value: "app"},
        kind: :client_secret
      )

    scoped = WardrikStore.scope(store, "wardrik_vault")
    sealed = WardrikStore.get(scoped, "org%3Aacme/GOOGLE_SECRET")
    {:ok, _vsn} = WardrikStore.put(scoped, "org%3Aacme/GOOGLE_SECRET", %{sealed | kind: :api_key})

    assert WardrikVault.fetch(vault, @acme, "GOOGLE_SECRET", kind: :api_key) ==
             {:error, :undecipherable}
  end

  test "won't unseal a value moved to another principal", %{vault: vault, store: store} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @acme, name: "github", value: "acme's"})

    scoped = WardrikStore.scope(store, "wardrik_vault")

    {:ok, _vsn} =
      WardrikStore.put(scoped, "user%3Ajon/github", WardrikStore.get(scoped, "org%3Aacme/github"))

    assert WardrikVault.fetch(vault, @jon, "github") == {:error, :undecipherable}
  end

  test "seals with the first key and unseals with any", %{vault: vault, store: store, key: old} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{
        principal: @jon,
        name: "github",
        value: "sealed with the old key"
      })

    rotated = start_vault(store, [WardrikVault.generate_key(), old], nil)

    assert WardrikVault.fetch(rotated, @jon, "github") == {:ok, "sealed with the old key"}

    {:ok, _vsn} =
      WardrikVault.put(rotated, %Secret{
        principal: @jon,
        name: "linear",
        value: "sealed with the new key"
      })

    assert WardrikVault.fetch(vault, @jon, "linear") == {:error, :undecipherable}
  end

  test "seals and unseals nothing without a key", %{store: store} do
    {vault, log} = with_log(fn -> start_vault(store, ["not a key"], nil) end)

    assert log =~ "isn't 32 bytes"

    assert WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "x"}) ==
             {:error, :no_key}

    assert WardrikVault.fetch(vault, @jon, "github") == {:error, :no_key}
  end

  test "writes over a version only while it's current", %{vault: vault} do
    {:ok, vsn} =
      WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "first"},
        kind: :grant,
        if_vsn: nil
      )

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "second"},
        kind: :grant,
        if_vsn: vsn
      )

    assert {:error, :conflict} =
             WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "third"},
               if_vsn: vsn
             )

    assert {:ok, :grant, "second", _vsn} = WardrikVault.lookup(vault, @jon, "github")
  end

  test "lists names and kinds, and deletes", %{vault: vault} do
    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "a"}, kind: :grant)

    {:ok, _vsn} =
      WardrikVault.put(vault, %Secret{principal: @jon, name: "linear/api", value: "b"})

    {:ok, _vsn} = WardrikVault.put(vault, %Secret{principal: @acme, name: "github", value: "c"})

    assert Enum.sort(WardrikVault.list(vault)) == [
             {"org:acme", "github", :secret},
             {"user:jon", "github", :grant},
             {"user:jon", "linear/api", :secret}
           ]

    assert WardrikVault.names(vault, @jon) == ["github", "linear/api"]
    assert :ok = WardrikVault.delete(vault, @jon, "github")
    assert WardrikVault.names(vault, @jon) == ["linear/api"]
  end

  describe "as an agent's credentials" do
    test "resolves a secret", %{vault: vault} do
      {:ok, _vsn} =
        WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "ghp_secret"})

      assert WardrikVault.resolve(credential("github", @jon), vault) == {:ok, "ghp_secret"}
    end

    test "renews a grant through its grants", %{vault: vault} do
      {:ok, vsn} =
        WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "token"},
          kind: :grant
        )

      assert WardrikVault.resolve(credential("github", @jon), vault) == {:ok, "renewed token"}
      assert_received {:renew, "github", %{value: "token", vsn: ^vsn}}
    end

    test "asks for a name nobody holds", %{vault: vault} do
      assert WardrikVault.resolve(credential("github", @jon), vault) ==
               {:authorize, "https://example.com/authorize/github"}

      assert_received {:ask, "github", "user:jon"}
    end

    test "asks again for a grant it can't unseal", %{vault: vault, store: store} do
      {:ok, _vsn} =
        WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "token"},
          kind: :grant
        )

      rotated = start_vault(store, [WardrikVault.generate_key()], {TestGrants, self()})

      assert capture_log(fn ->
               assert {:authorize, _url} =
                        WardrikVault.resolve(credential("github", @jon), rotated)
             end) =~ "asking again"
    end

    test "tells its grants a grant was refused, and ignores a refused secret", %{vault: vault} do
      {:ok, _vsn} =
        WardrikVault.put(vault, %Secret{principal: @jon, name: "github", value: "token"},
          kind: :grant
        )

      {:ok, _vsn} =
        WardrikVault.put(vault, %Secret{principal: @jon, name: "linear", value: "secret"})

      assert :ok = WardrikVault.refused(credential("github", @jon), vault)
      assert :ok = WardrikVault.refused(credential("linear", @jon), vault)
      assert_received {:refused, "github"}
      refute_received {:refused, "linear"}
    end

    test "resolves nothing without a principal, or without grants", %{vault: vault, store: store} do
      assert WardrikVault.resolve(credential("github", nil), vault) == {:error, :no_principal}
      assert WardrikVault.refused(credential("github", nil), vault) == :ok

      plain = start_vault(store, [WardrikVault.generate_key()], nil)
      assert WardrikVault.resolve(credential("github", @jon), plain) == {:error, :not_found}
    end

    test "parks a tool's call on the sign-in its grants ask for", %{vault: vault} do
      context =
        WardrikCore.Context.new(
          agent_id: "digest",
          principal: @jon,
          credentials: {WardrikVault, vault}
        )

      assert {:park, %WardrikCore.Authorization{credential: "github", principal: @jon}} =
               WardrikCore.Credentials.fetch(context, "github")
    end
  end
end
