defmodule WardrikVaultTest do
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Test.Calls
  alias WardrikVault.Sealed

  setup do
    Process.put(:vault, WardrikVault.new(store: store(), keys: [WardrikVault.generate_key()]))

    %{user: "jon-#{System.unique_integer([:positive])}"}
  end

  # Grants as a module renewing and asking for them would: it says what it was
  # handed, so a test sees which way the vault went.
  defmodule Grants do
    defstruct []
  end

  defimpl WardrikVault.Grants, for: Grants do
    def grants?(_grants, name, _owner), do: name == "github"

    def renew(_grants, name, owner, opts) do
      %WardrikVault{} = Keyword.fetch!(opts, :vault)
      value = Keyword.fetch!(opts, :value)
      {:ok, Credential.secret("renewed #{value}", owner: owner, expires_at: byte_size(name))}
    end

    def ask(_grants, name, owner, vault: %WardrikVault{}),
      do: {:error, {:authorization_required, %{url: "https://#{name}.test", code: nil}, owner}}

    def refused(_grants, _name, owner, vault: %WardrikVault{}) do
      send(self(), {:refused, owner})
      :ok
    end
  end

  # The vault a test works on, which a test may give other grants or keys.
  defp vault, do: Process.get(:vault)
  defp grants(grants), do: Process.put(:vault, %{vault() | grants: grants})
  defp keys(list), do: Process.put(:vault, %{vault() | keys: list})

  defp call(run_opts), do: Calls.tool("tool", %{}, run(run_opts))

  defp run(opts) do
    {user, opts} = Keyword.pop(opts, :user)
    {org, opts} = Keyword.pop(opts, :org, "acme")
    host = Wardrik.Test.host(credentials: vault())
    opts = Keyword.put_new(opts, :host, host)
    Run.root(Config.new(), Wardrik.AgentID.new!("assistant", org: org, user: user), opts)
  end

  defp environment_variable(value) do
    name = "WARDRIK_VAULT_TEST_#{System.unique_integer([:positive])}"
    System.put_env(name, value)
    on_exit(fn -> System.delete_env(name) end)
    name
  end

  describe "path/2" do
    test "writes distinct owners and names under distinct keys" do
      paths =
        for {name, owner} <- [
              {"github", "jon doe"},
              {"github", "jon_doe"},
              {"github", "jon/doe"},
              {"github", "_"},
              {"github", nil},
              {"github", {"acme", "jon"}},
              {"github", {"globex", "jon"}},
              {"git hub", "jon"},
              {"git_hub", "jon"}
            ],
            do: WardrikVault.path(name, owner)

      assert length(Enum.uniq(paths)) == length(paths)
      assert WardrikVault.path("github", "jon") == "jon/github"
    end
  end

  describe "put/4, fetch/2 and lookup/2" do
    test "hand back what was put, and say whether it is a secret or a grant", %{user: user} do
      assert :ok = WardrikVault.put(vault(), "github", user, value: "ghp_secret")
      assert {:ok, "ghp_secret"} = WardrikVault.fetch(vault(), "github", user)
      assert {:ok, :secret, "ghp_secret"} = WardrikVault.lookup(vault(), "github", user)

      :ok = WardrikVault.put(vault(), "github", user, value: "token", kind: :grant)
      assert {:ok, :grant, "token"} = WardrikVault.lookup(vault(), "github", user)
    end

    test "keep one owner's, and one name's, from another", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "mine")

      assert {:error, :not_found} = WardrikVault.fetch(vault(), "github", "someone-else")
      assert {:error, :not_found} = WardrikVault.fetch(vault(), "linear", user)
    end

    test "a second put replaces the first", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "old")
      :ok = WardrikVault.put(vault(), "github", user, value: "new")

      assert {:ok, "new"} = WardrikVault.fetch(vault(), "github", user)
    end
  end

  describe "what is written down" do
    test "is sealed, and says nothing when inspected", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "ghp_secret")

      {%Sealed{} = sealed, _vsn} =
        WardrikStore.lookup(store(), WardrikVault.namespace(), WardrikVault.path("github", user))

      refute inspect(sealed) =~ "ghp_secret"
      refute sealed.ciphertext =~ "ghp_secret"
      assert inspect(sealed) =~ "sealed"
    end

    test "will not unseal under another owner's path, or as another kind", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "ghp_secret", kind: :grant)
      mine = WardrikVault.path("github", user)
      theirs = WardrikVault.path("github", "thief")

      {sealed, _vsn} = WardrikStore.lookup(store(), WardrikVault.namespace(), mine)
      {:ok, _vsn} = WardrikStore.put(store(), WardrikVault.namespace(), theirs, sealed)
      assert {:error, :grant, :undecipherable} = WardrikVault.lookup(vault(), "github", "thief")

      {:ok, _vsn} =
        WardrikStore.put(store(), WardrikVault.namespace(), mine, %{sealed | kind: :secret})

      assert {:error, :secret, :undecipherable} = WardrikVault.lookup(vault(), "github", user)
    end

    test "is not read where it is not sealed, or sealed by a version this one does not know",
         %{user: user} do
      path = WardrikVault.path("github", user)

      {:ok, _vsn} = WardrikStore.put(store(), WardrikVault.namespace(), path, "ghp_plain")
      assert {:error, {:unreadable, "ghp_plain"}} = WardrikVault.fetch(vault(), "github", user)

      :ok = WardrikVault.put(vault(), "github", user, value: "ghp_secret")
      {sealed, _vsn} = WardrikStore.lookup(store(), WardrikVault.namespace(), path)

      {:ok, _vsn} =
        WardrikStore.put(store(), WardrikVault.namespace(), path, %{sealed | version: 99})

      assert {:error, {:unknown_version, 99}} = WardrikVault.fetch(vault(), "github", user)
    end
  end

  describe "keys" do
    test "a rotated key still reads what the old one sealed", %{user: user} do
      [old] = vault().keys
      :ok = WardrikVault.put(vault(), "github", user, value: "ghp_secret")

      keys([WardrikVault.generate_key(), old])

      assert {:ok, "ghp_secret"} = WardrikVault.fetch(vault(), "github", user)
    end

    test "a key that is gone cannot read what it sealed", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "ghp_secret")

      keys([WardrikVault.generate_key()])

      assert {:error, :undecipherable} = WardrikVault.fetch(vault(), "github", user)
    end

    test "with no key nothing is written and nothing is read", %{user: user} do
      keys([])

      assert {:error, :no_key} = WardrikVault.put(vault(), "github", user, value: "ghp_secret")
      assert {:error, :no_key} = WardrikVault.fetch(vault(), "github", user)
      refute WardrikVault.ready?(vault())
    end

    test "a key is 32 bytes in base64, and anything else is not one" do
      assert WardrikVault.key?(WardrikVault.generate_key())
      refute WardrikVault.key?(Base.encode64("too short"))
      refute WardrikVault.key?("not base64!")
      refute WardrikVault.key?(nil)
    end

    test "is configured where a key is named, usable or not" do
      keys([])
      refute WardrikVault.configured?(vault())

      keys(["not a key"])
      assert WardrikVault.configured?(vault())
      refute WardrikVault.ready?(vault())
    end

    test "generate_key/0 makes a key the vault accepts" do
      keys([WardrikVault.generate_key()])

      assert WardrikVault.ready?(vault())
    end
  end

  describe "as the host's Wardrik.Credentials" do
    test "takes the owner's alone, never another's", %{user: user} do
      org = "org-#{user}"

      :ok = WardrikVault.put(vault(), "tracker", nil, value: "deployment")
      assert {:error, :not_found} = Credential.resolve(call(org: org), "tracker")

      :ok = WardrikVault.put(vault(), "tracker", org, value: "org")
      assert {:ok, credential} = Credential.resolve(call(org: org), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"org", org}
      assert {:error, :not_found} = Credential.resolve(call(org: org, user: user), "tracker")

      :ok = WardrikVault.put(vault(), "tracker", {org, user}, value: "user")
      assert {:ok, credential} = Credential.resolve(call(org: org, user: user), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"user", {org, user}}

      assert {:ok, credential} = Credential.resolve(call(org: org), "tracker")
      assert credential.owner == org
    end

    test "a user's is theirs within their org, and no one else's", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", {"acme", user}, value: "acme-token")

      assert {:error, :not_found} =
               Credential.resolve(call(org: "globex", user: user), "github")

      assert {:error, :not_found} =
               Credential.resolve(call(org: "acme", user: "someone-else"), "github")

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "github")
      assert Credential.reveal(credential) == "acme-token"
    end

    test "is the agent's owner's, whoever asked for the turn", %{user: user} do
      :ok = WardrikVault.put(vault(), "tracker", {"acme", user}, value: "theirs")

      for sender <- [
            nil,
            Wardrik.Principal.new(:shell, "root"),
            Wardrik.Principal.new(:user, user)
          ] do
        assert {:ok, credential} = Credential.resolve(call(user: user, sender: sender), "tracker")
        assert Credential.reveal(credential) == "theirs"
      end
    end

    test "a name nobody holds is not found, without a grants module that grants it", %{
      user: user
    } do
      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), "nothing")

      grants(%Grants{})
      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), "nothing")
    end

    test "a shared name is the deployment's, where the owner holds none", %{user: user} do
      :ok = WardrikVault.put(vault(), "linear", nil, value: "deployment")
      Process.put(:vault, %{vault() | shared: ["linear"]})

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "linear")
      assert {Credential.reveal(credential), credential.owner} == {"deployment", nil}

      :ok = WardrikVault.put(vault(), "linear", {"acme", user}, value: "sealed")
      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "linear")
      assert Credential.reveal(credential) == "sealed"
    end

    test "a shared name the vault holds none of is the node's environment variable", %{user: user} do
      name = environment_variable("from-the-environment")
      Process.put(:vault, %{vault() | shared: [name]})

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), name)
      assert {Credential.reveal(credential), credential.owner} == {"from-the-environment", nil}
    end

    test "a shared name resolves where the vault has no key", %{user: user} do
      name = environment_variable("keyless")
      Process.put(:vault, %{vault() | keys: [], shared: [name]})

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), name)
      assert Credential.reveal(credential) == "keyless"
      assert {:error, :no_key} = Credential.resolve(call(org: "acme", user: user), "github")
    end

    test "a name the deployment does not share reaches no agent", %{user: user} do
      name = environment_variable("unnamed")
      :ok = WardrikVault.put(vault(), name, nil, value: "deployment")

      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), name)
      assert {:error, :not_found} = Credential.resolve(call(org: "acme"), name)
    end

    test "a grant is handed to the grants module to answer, and to renew", %{user: user} do
      grants(%Grants{})
      :ok = WardrikVault.put(vault(), "github", {"acme", user}, value: "token", kind: :grant)

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "github")
      assert Credential.reveal(credential) == "renewed token"
      assert credential.owner == {"acme", user}

      assert :ok = Credential.refused(call(org: "acme", user: user), "github")
      assert_received {:refused, {"acme", ^user}}
    end

    test "a name nobody holds that the grants module grants is asked of the user, or the org",
         %{user: user} do
      grants(%Grants{})
      org = "org-#{user}"

      assert {:error, {:authorization_required, %{url: "https://github.test"}, {^org, ^user}}} =
               Credential.resolve(call(org: org, user: user), "github")

      assert {:error, {:authorization_required, %{url: "https://github.test"}, ^org}} =
               Credential.resolve(call(org: org), "github")
    end

    test "an org's grant reaches the org's own calls, and a user is asked for theirs",
         %{user: user} do
      grants(%Grants{})
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "github", org, value: "org-token", kind: :grant)
      :ok = WardrikVault.put(vault(), "github", nil, value: "deployment-token", kind: :grant)

      assert {:ok, credential} = Credential.resolve(call(org: org), "github")
      assert {Credential.reveal(credential), credential.owner} == {"renewed org-token", org}

      assert {:error, {:authorization_required, _link, {^org, ^user}}} =
               Credential.resolve(call(org: org, user: user), "github")

      assert :ok = Credential.refused(call(org: org, user: user), "github")
      refute_received {:refused, _owner}

      :ok = WardrikVault.forget(vault(), "github", nil)
    end

    test "a secret held for the name is the answer, and no grant is asked for", %{user: user} do
      grants(%Grants{})
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "github", {org, user}, value: "user-token")

      assert {:ok, credential} = Credential.resolve(call(org: org, user: user), "github")
      assert Credential.reveal(credential) == "user-token"
      assert :ok = Credential.refused(call(org: org, user: user), "github")
      refute_received {:refused, _owner}
    end

    test "a grant that no longer unseals is asked for again", %{user: user} do
      grants(%Grants{})
      :ok = WardrikVault.put(vault(), "github", {"acme", user}, value: "token", kind: :grant)
      [old] = vault().keys
      keys([WardrikVault.generate_key()])
      grants(%Grants{})

      assert {:error, {:authorization_required, _link, {"acme", ^user}}} =
               Credential.resolve(call(org: "acme", user: user), "github")

      keys([old])
    end
  end

  describe "names/1, list/0 and forget/2" do
    test "list what an owner holds, without reading any of it", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "a")
      :ok = WardrikVault.put(vault(), "git_hub key", user, value: "b")

      assert Enum.sort(WardrikVault.names(vault(), user)) == ["git_hub key", "github"]
    end

    test "list every credential, with each owner written as text", %{user: user} do
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "#{user}_TOKEN", nil, value: "a")
      :ok = WardrikVault.put(vault(), "linear", org, value: "b")
      :ok = WardrikVault.put(vault(), "github", {org, user}, value: "c", kind: :grant)

      listed = WardrikVault.list(vault())

      assert {"#{user}_TOKEN", nil} in listed
      assert {"linear", org} in listed
      assert {"github", :hashed} in listed
    end

    test "forgetting removes one, and forgetting twice is still fine", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", user, value: "a")

      assert :ok = WardrikVault.forget(vault(), "github", user)
      assert :ok = WardrikVault.forget(vault(), "github", user)
      assert {:error, :not_found} = WardrikVault.fetch(vault(), "github", user)
      refute WardrikVault.has?(vault(), "github", user)
    end
  end

  describe "as a value" do
    test "shows its store and how many keys it holds, never a key" do
      key = WardrikVault.generate_key()
      shown = inspect(WardrikVault.new(store: store(), keys: [key]))

      assert shown =~ "#WardrikVault<"
      assert shown =~ "1 keys>"
      refute shown =~ key
    end

    test "answers a provider's key as the deployment's secret of its name" do
      vault = vault()
      :ok = WardrikVault.put(vault, "XAI_API_KEY", nil, value: "xai-vault")
      on_exit(fn -> WardrikVault.forget(vault, "XAI_API_KEY", nil) end)

      assert Wardrik.Credentials.key(vault(), "XAI_API_KEY") == {:ok, "xai-vault"}
      assert Wardrik.Credentials.key(vault(), "NOBODY_SEALED_THIS") == :error
    end

    test "grants nothing without grants of its own", %{user: user} do
      none = %WardrikVault.Grants.None{}

      refute WardrikVault.Grants.grants?(none, "github", "acme")

      assert WardrikVault.Grants.renew(none, "github", user, vault: vault(), value: "t") ==
               {:error, :not_found}

      assert WardrikVault.Grants.ask(none, "github", user, vault: vault()) == {:error, :not_found}
      assert WardrikVault.Grants.refused(none, "github", user, vault: vault()) == :ok
    end

    test "tells its grants of a refusal through the host's credentials", %{user: user} do
      grants(%Grants{})
      :ok = WardrikVault.put(vault(), "github", {"acme", user}, value: "t", kind: :grant)

      assert Wardrik.Credential.refused(call(org: "acme", user: user), "github") == :ok
      assert_received {:refused, {"acme", ^user}}
    end
  end
end
