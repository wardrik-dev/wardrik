defmodule WardrikVaultTest do
  use ExUnit.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikVault.Sealed

  setup do
    previous = WardrikVault.Config.settings()
    :ignore = WardrikVault.start_link(keys: [WardrikVault.generate_key()])
    on_exit(fn -> WardrikVault.start_link(previous) end)

    %{user: "jon-#{System.unique_integer([:positive])}"}
  end

  # Grants as a module renewing and asking for them would: it says what it was
  # handed, so a test sees which way the vault went.
  defmodule Grants do
    @behaviour WardrikVault.Grants

    @impl true
    def grants?(name), do: name == "github"

    @impl true
    def renew(name, owner, value),
      do: {:ok, Credential.secret("renewed #{value}", owner: owner, expires_at: byte_size(name))}

    @impl true
    def ask(name, owner),
      do: {:error, {:authorization_required, %{url: "https://#{name}.test", code: nil}, owner}}

    @impl true
    def refused(_name, owner) do
      send(self(), {:refused, owner})
      :ok
    end
  end

  defp grants(module),
    do: WardrikVault.start_link(Keyword.put(WardrikVault.Config.settings(), :grants, module))

  defp call(scope_opts) do
    Calls.tool("tool", %{}, scope([credentials: WardrikVault] ++ scope_opts))
  end

  defp scope(opts) do
    {user, opts} = Keyword.pop(opts, :user)
    {org, opts} = Keyword.pop(opts, :org, "acme")
    Scope.root(Config.new(), Wardrik.AgentID.new!("assistant", org: org, user: user), opts)
  end

  defp keys(list), do: WardrikVault.start_link(keys: list)

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
      assert :ok = WardrikVault.put("github", user, "ghp_secret")
      assert {:ok, "ghp_secret"} = WardrikVault.fetch("github", user)
      assert {:ok, :secret, "ghp_secret"} = WardrikVault.lookup("github", user)

      :ok = WardrikVault.put("github", user, "token", kind: :grant)
      assert {:ok, :grant, "token"} = WardrikVault.lookup("github", user)
    end

    test "keep one owner's, and one name's, from another", %{user: user} do
      :ok = WardrikVault.put("github", user, "mine")

      assert {:error, :not_found} = WardrikVault.fetch("github", "someone-else")
      assert {:error, :not_found} = WardrikVault.fetch("linear", user)
    end

    test "a second put replaces the first", %{user: user} do
      :ok = WardrikVault.put("github", user, "old")
      :ok = WardrikVault.put("github", user, "new")

      assert {:ok, "new"} = WardrikVault.fetch("github", user)
    end
  end

  describe "what is written down" do
    test "is sealed, and says nothing when inspected", %{user: user} do
      :ok = WardrikVault.put("github", user, "ghp_secret")

      {%Sealed{} = sealed, _vsn} =
        Wardrik.Store.lookup(WardrikVault.namespace(), WardrikVault.path("github", user))

      refute inspect(sealed) =~ "ghp_secret"
      refute sealed.ciphertext =~ "ghp_secret"
      assert inspect(sealed) =~ "sealed"
    end

    test "will not unseal under another owner's path, or as another kind", %{user: user} do
      :ok = WardrikVault.put("github", user, "ghp_secret", kind: :grant)
      mine = WardrikVault.path("github", user)
      theirs = WardrikVault.path("github", "thief")

      {sealed, _vsn} = Wardrik.Store.lookup(WardrikVault.namespace(), mine)
      {:ok, _vsn} = Wardrik.Store.put(WardrikVault.namespace(), theirs, sealed)
      assert {:error, :grant, :undecipherable} = WardrikVault.lookup("github", "thief")

      {:ok, _vsn} = Wardrik.Store.put(WardrikVault.namespace(), mine, %{sealed | kind: :secret})
      assert {:error, :secret, :undecipherable} = WardrikVault.lookup("github", user)
    end

    test "is not read where it is not sealed, or sealed by a version this one does not know",
         %{user: user} do
      path = WardrikVault.path("github", user)

      {:ok, _vsn} = Wardrik.Store.put(WardrikVault.namespace(), path, "ghp_plain")
      assert {:error, {:unreadable, "ghp_plain"}} = WardrikVault.fetch("github", user)

      :ok = WardrikVault.put("github", user, "ghp_secret")
      {sealed, _vsn} = Wardrik.Store.lookup(WardrikVault.namespace(), path)
      {:ok, _vsn} = Wardrik.Store.put(WardrikVault.namespace(), path, %{sealed | version: 99})
      assert {:error, {:unknown_version, 99}} = WardrikVault.fetch("github", user)
    end
  end

  describe "keys" do
    test "a rotated key still reads what the old one sealed", %{user: user} do
      [old] = WardrikVault.Config.keys()
      :ok = WardrikVault.put("github", user, "ghp_secret")

      keys([WardrikVault.generate_key(), old])

      assert {:ok, "ghp_secret"} = WardrikVault.fetch("github", user)
    end

    test "a key that is gone cannot read what it sealed", %{user: user} do
      :ok = WardrikVault.put("github", user, "ghp_secret")

      keys([WardrikVault.generate_key()])

      assert {:error, :undecipherable} = WardrikVault.fetch("github", user)
    end

    test "with no key nothing is written and nothing is read", %{user: user} do
      keys([])

      assert {:error, :no_key} = WardrikVault.put("github", user, "ghp_secret")
      assert {:error, :no_key} = WardrikVault.fetch("github", user)
      refute WardrikVault.ready?()
    end

    test "a key is 32 bytes in base64, and anything else is not one" do
      assert WardrikVault.key?(WardrikVault.generate_key())
      refute WardrikVault.key?(Base.encode64("too short"))
      refute WardrikVault.key?("not base64!")
      refute WardrikVault.key?(nil)
    end

    test "is configured where a key is named, usable or not" do
      keys([])
      refute WardrikVault.Config.configured?()

      keys(["not a key"])
      assert WardrikVault.Config.configured?()
      refute WardrikVault.ready?()
    end

    test "generate_key/0 makes a key the vault accepts" do
      keys([WardrikVault.generate_key()])

      assert WardrikVault.ready?()
    end
  end

  describe "as a Wardrik.Credential resolver" do
    test "takes the user's, then the org's, then the deployment's", %{user: user} do
      org = "org-#{user}"
      scope = [org: org, user: user]

      :ok = WardrikVault.put("tracker", nil, "deployment")
      assert {:ok, credential} = Credential.resolve(call(scope), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"deployment", nil}

      :ok = WardrikVault.put("tracker", org, "org")
      assert {:ok, credential} = Credential.resolve(call(scope), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"org", org}

      :ok = WardrikVault.put("tracker", {org, user}, "user")
      assert {:ok, credential} = Credential.resolve(call(scope), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"user", {org, user}}

      assert {:ok, credential} = Credential.resolve(call(org: org), "tracker")
      assert credential.owner == org
    end

    test "a user's is theirs within their org, and no one else's", %{user: user} do
      :ok = WardrikVault.put("github", {"acme", user}, "acme-token")

      assert {:error, :not_found} =
               Credential.resolve(call(org: "globex", user: user), "github")

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "github")
      assert Credential.reveal(credential) == "acme-token"
    end

    test "a name nobody holds is not found, without a grants module that grants it", %{
      user: user
    } do
      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), "nothing")

      grants(Grants)
      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), "nothing")
    end

    test "a name the environment sets, as :environment names it, is the deployment's where nobody holds it",
         %{user: user} do
      name = environment_variable("from-the-environment")

      :ignore =
        WardrikVault.start_link(Keyword.put(WardrikVault.Config.settings(), :environment, [name]))

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), name)
      assert Credential.reveal(credential) == "from-the-environment"
      assert credential.owner == nil

      :ok = WardrikVault.put(name, {"acme", user}, "sealed")
      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), name)
      assert Credential.reveal(credential) == "sealed"
    end

    test "a name the environment sets resolves where the vault has no key", %{user: user} do
      name = environment_variable("keyless")
      :ignore = WardrikVault.start_link(environment: [name])

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), name)
      assert Credential.reveal(credential) == "keyless"
      assert {:error, :no_key} = Credential.resolve(call(org: "acme", user: user), "github")
    end

    test "a name the environment sets is not read unless :environment names it", %{user: user} do
      name = environment_variable("unnamed")

      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), name)
    end

    test "a grant is handed to the grants module to answer, and to renew", %{user: user} do
      grants(Grants)
      :ok = WardrikVault.put("github", {"acme", user}, "token", kind: :grant)

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "github")
      assert Credential.reveal(credential) == "renewed token"
      assert credential.owner == {"acme", user}

      assert :ok = Credential.refused(call(org: "acme", user: user), "github")
      assert_received {:refused, {"acme", ^user}}
    end

    test "a name nobody holds that the grants module grants is asked of the user, or the org",
         %{user: user} do
      grants(Grants)
      org = "org-#{user}"

      assert {:error, {:authorization_required, %{url: "https://github.test"}, {^org, ^user}}} =
               Credential.resolve(call(org: org, user: user), "github")

      assert {:error, {:authorization_required, %{url: "https://github.test"}, ^org}} =
               Credential.resolve(call(org: org), "github")
    end

    test "an org's grant reaches the org's own calls, and a user is asked for theirs",
         %{user: user} do
      grants(Grants)
      org = "org-#{user}"
      :ok = WardrikVault.put("github", org, "org-token", kind: :grant)
      :ok = WardrikVault.put("github", nil, "deployment-token", kind: :grant)

      assert {:ok, credential} = Credential.resolve(call(org: org), "github")
      assert {Credential.reveal(credential), credential.owner} == {"renewed org-token", org}

      assert {:error, {:authorization_required, _link, {^org, ^user}}} =
               Credential.resolve(call(org: org, user: user), "github")

      assert :ok = Credential.refused(call(org: org, user: user), "github")
      refute_received {:refused, _owner}

      :ok = WardrikVault.forget("github", nil)
    end

    test "a secret held for the name is the answer, and no grant is asked for", %{user: user} do
      grants(Grants)
      org = "org-#{user}"
      :ok = WardrikVault.put("github", org, "org-token")

      assert {:ok, credential} = Credential.resolve(call(org: org, user: user), "github")
      assert Credential.reveal(credential) == "org-token"
      assert :ok = Credential.refused(call(org: org, user: user), "github")
      refute_received {:refused, _owner}
    end

    test "a grant that no longer unseals is asked for again", %{user: user} do
      grants(Grants)
      :ok = WardrikVault.put("github", {"acme", user}, "token", kind: :grant)
      [old] = WardrikVault.Config.keys()
      keys([WardrikVault.generate_key()])
      grants(Grants)

      assert {:error, {:authorization_required, _link, {"acme", ^user}}} =
               Credential.resolve(call(org: "acme", user: user), "github")

      keys([old])
    end
  end

  describe "names/1, list/0 and forget/2" do
    test "list what an owner holds, without reading any of it", %{user: user} do
      :ok = WardrikVault.put("github", user, "a")
      :ok = WardrikVault.put("git_hub key", user, "b")

      assert Enum.sort(WardrikVault.names(user)) == ["git_hub key", "github"]
    end

    test "list every credential, with each owner written as text", %{user: user} do
      org = "org-#{user}"
      :ok = WardrikVault.put("#{user}_TOKEN", nil, "a")
      :ok = WardrikVault.put("linear", org, "b")
      :ok = WardrikVault.put("github", {org, user}, "c", kind: :grant)

      listed = WardrikVault.list()

      assert {"#{user}_TOKEN", nil} in listed
      assert {"linear", org} in listed
      assert {"github", :hashed} in listed
    end

    test "forgetting removes one, and forgetting twice is still fine", %{user: user} do
      :ok = WardrikVault.put("github", user, "a")

      assert :ok = WardrikVault.forget("github", user)
      assert :ok = WardrikVault.forget("github", user)
      assert {:error, :not_found} = WardrikVault.fetch("github", user)
      refute WardrikVault.has?("github", user)
    end
  end
end
