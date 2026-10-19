defmodule WardrikVaultTest do
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Resource
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

  defp ns(text), do: Resource.parse!(text)
  defp person(org, user), do: ns("#{org}/@#{user}")

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
              {"github", ns("jon")},
              {"github", ns("jon_doe")},
              {"github", ns("jon/@doe")},
              {"github", ns("jon-doe")},
              {"github", Resource.deployment()},
              {"github", ns("acme/@jon")},
              {"github", ns("globex/@jon")},
              {"git hub", ns("jon")},
              {"git_hub", ns("jon")}
            ],
            do: WardrikVault.path(name, owner)

      assert length(Enum.uniq(paths)) == length(paths)
      assert WardrikVault.path("github", ns("jon")) == "jon/github"
      assert WardrikVault.path("github", ns("acme/@jon")) == "acme%2F%40jon/github"
    end
  end

  describe "put/4, fetch/2 and lookup/2" do
    test "hand back what was put, and say whether it is a secret or a grant", %{user: user} do
      assert :ok = WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret")
      assert {:ok, "ghp_secret"} = WardrikVault.fetch(vault(), "github", ns(user))
      assert {:ok, :secret, "ghp_secret"} = WardrikVault.lookup(vault(), "github", ns(user))

      :ok = WardrikVault.put(vault(), "github", ns(user), value: "token", kind: :grant)
      assert {:ok, :grant, "token"} = WardrikVault.lookup(vault(), "github", ns(user))
    end

    test "keep one owner's, and one name's, from another", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "mine")

      assert {:error, :not_found} = WardrikVault.fetch(vault(), "github", ns("someone-else"))
      assert {:error, :not_found} = WardrikVault.fetch(vault(), "linear", ns(user))
    end

    test "a second put replaces the first", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "old")
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "new")

      assert {:ok, "new"} = WardrikVault.fetch(vault(), "github", ns(user))
    end
  end

  describe "what is written down" do
    test "is sealed, and says nothing when inspected", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret")

      {%Sealed{} = sealed, _vsn} =
        WardrikStore.lookup(
          store(),
          WardrikVault.namespace(),
          WardrikVault.path("github", ns(user))
        )

      refute inspect(sealed) =~ "ghp_secret"
      refute sealed.ciphertext =~ "ghp_secret"
      assert inspect(sealed) =~ "sealed"
    end

    test "will not unseal under another owner's path, or as another kind", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret", kind: :grant)
      mine = WardrikVault.path("github", ns(user))
      theirs = WardrikVault.path("github", ns("thief"))

      {sealed, _vsn} = WardrikStore.lookup(store(), WardrikVault.namespace(), mine)
      {:ok, _vsn} = WardrikStore.put(store(), WardrikVault.namespace(), theirs, sealed)

      assert {:error, :grant, :undecipherable} =
               WardrikVault.lookup(vault(), "github", ns("thief"))

      {:ok, _vsn} =
        WardrikStore.put(store(), WardrikVault.namespace(), mine, %{sealed | kind: :secret})

      assert {:error, :secret, :undecipherable} = WardrikVault.lookup(vault(), "github", ns(user))
    end

    test "is not read where it is not sealed, or sealed by a version this one does not know",
         %{user: user} do
      path = WardrikVault.path("github", ns(user))

      {:ok, _vsn} = WardrikStore.put(store(), WardrikVault.namespace(), path, "ghp_plain")

      assert {:error, {:unreadable, "ghp_plain"}} =
               WardrikVault.fetch(vault(), "github", ns(user))

      :ok = WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret")
      {sealed, _vsn} = WardrikStore.lookup(store(), WardrikVault.namespace(), path)

      {:ok, _vsn} =
        WardrikStore.put(store(), WardrikVault.namespace(), path, %{sealed | version: 99})

      assert {:error, {:unknown_version, 99}} = WardrikVault.fetch(vault(), "github", ns(user))
    end
  end

  describe "keys" do
    test "a rotated key still reads what the old one sealed", %{user: user} do
      [old] = vault().keys
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret")

      keys([WardrikVault.generate_key(), old])

      assert {:ok, "ghp_secret"} = WardrikVault.fetch(vault(), "github", ns(user))
    end

    test "a key that is gone cannot read what it sealed", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret")

      keys([WardrikVault.generate_key()])

      assert {:error, :undecipherable} = WardrikVault.fetch(vault(), "github", ns(user))
    end

    test "with no key nothing is written and nothing is read", %{user: user} do
      keys([])

      assert {:error, :no_key} =
               WardrikVault.put(vault(), "github", ns(user), value: "ghp_secret")

      assert {:error, :no_key} = WardrikVault.fetch(vault(), "github", ns(user))
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

      :ok = WardrikVault.put(vault(), "tracker", Resource.deployment(), value: "deployment")
      assert {:error, :not_found} = Credential.resolve(call(org: org), "tracker")

      :ok = WardrikVault.put(vault(), "tracker", ns(org), value: "org")
      assert {:ok, credential} = Credential.resolve(call(org: org), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"org", ns(org)}
      assert {:error, :not_found} = Credential.resolve(call(org: org, user: user), "tracker")

      :ok = WardrikVault.put(vault(), "tracker", person(org, user), value: "user")
      assert {:ok, credential} = Credential.resolve(call(org: org, user: user), "tracker")
      assert {Credential.reveal(credential), credential.owner} == {"user", person(org, user)}

      assert {:ok, credential} = Credential.resolve(call(org: org), "tracker")
      assert credential.owner == ns(org)
    end

    test "a user's is theirs within their org, and no one else's", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", person("acme", user), value: "acme-token")

      assert {:error, :not_found} =
               Credential.resolve(call(org: "globex", user: user), "github")

      assert {:error, :not_found} =
               Credential.resolve(call(org: "acme", user: "someone-else"), "github")

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "github")
      assert Credential.reveal(credential) == "acme-token"
    end

    test "is the agent's owner's, whoever asked for the turn", %{user: user} do
      :ok = WardrikVault.put(vault(), "tracker", person("acme", user), value: "theirs")

      for sender <- [
            nil,
            Wardrik.Principal.new("shell:root"),
            Wardrik.Principal.new("acme/@#{user}")
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
      :ok = WardrikVault.put(vault(), "linear", Resource.deployment(), value: "deployment")
      Process.put(:vault, %{vault() | shared: ["linear"]})

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "linear")

      assert {Credential.reveal(credential), credential.owner} ==
               {"deployment", Resource.deployment()}

      :ok = WardrikVault.put(vault(), "linear", person("acme", user), value: "sealed")
      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "linear")
      assert Credential.reveal(credential) == "sealed"
    end

    test "a shared name the vault holds none of is the node's environment variable", %{user: user} do
      name = environment_variable("from-the-environment")
      Process.put(:vault, %{vault() | shared: [name]})

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), name)

      assert {Credential.reveal(credential), credential.owner} ==
               {"from-the-environment", Resource.deployment()}
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
      :ok = WardrikVault.put(vault(), name, Resource.deployment(), value: "deployment")

      assert {:error, :not_found} = Credential.resolve(call(org: "acme", user: user), name)
      assert {:error, :not_found} = Credential.resolve(call(org: "acme"), name)
    end

    test "a grant is handed to the grants module to answer, and to renew", %{user: user} do
      grants(%Grants{})

      :ok =
        WardrikVault.put(vault(), "github", person("acme", user), value: "token", kind: :grant)

      assert {:ok, credential} = Credential.resolve(call(org: "acme", user: user), "github")
      assert Credential.reveal(credential) == "renewed token"
      assert credential.owner == person("acme", user)

      assert :ok = Credential.refused(call(org: "acme", user: user), "github")
      assert_received {:refused, owner}
      assert owner == person("acme", user)
    end

    test "a name nobody holds that the grants module grants is asked of the user, or the org",
         %{user: user} do
      grants(%Grants{})
      org = "org-#{user}"

      assert {:error, {:authorization_required, %{url: "https://github.test"}, owner}} =
               Credential.resolve(call(org: org, user: user), "github")

      assert owner == person(org, user)

      assert {:error, {:authorization_required, %{url: "https://github.test"}, owner}} =
               Credential.resolve(call(org: org), "github")

      assert owner == ns(org)
    end

    test "an org's grant reaches the org's own calls, and a user is asked for theirs",
         %{user: user} do
      grants(%Grants{})
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "github", ns(org), value: "org-token", kind: :grant)

      :ok =
        WardrikVault.put(vault(), "github", Resource.deployment(),
          value: "deployment-token",
          kind: :grant
        )

      assert {:ok, credential} = Credential.resolve(call(org: org), "github")
      assert {Credential.reveal(credential), credential.owner} == {"renewed org-token", ns(org)}

      assert {:error, {:authorization_required, _link, owner}} =
               Credential.resolve(call(org: org, user: user), "github")

      assert owner == person(org, user)

      assert :ok = Credential.refused(call(org: org, user: user), "github")
      refute_received {:refused, _owner}

      :ok = WardrikVault.forget(vault(), "github", Resource.deployment())
    end

    test "a secret held for the name is the answer, and no grant is asked for", %{user: user} do
      grants(%Grants{})
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "github", person(org, user), value: "user-token")

      assert {:ok, credential} = Credential.resolve(call(org: org, user: user), "github")
      assert Credential.reveal(credential) == "user-token"
      assert :ok = Credential.refused(call(org: org, user: user), "github")
      refute_received {:refused, _owner}
    end

    test "a grant that no longer unseals is asked for again", %{user: user} do
      grants(%Grants{})

      :ok =
        WardrikVault.put(vault(), "github", person("acme", user), value: "token", kind: :grant)

      [old] = vault().keys
      keys([WardrikVault.generate_key()])
      grants(%Grants{})

      assert {:error, {:authorization_required, _link, owner}} =
               Credential.resolve(call(org: "acme", user: user), "github")

      assert owner == person("acme", user)

      keys([old])
    end
  end

  describe "names/1, list/0 and forget/2" do
    test "list what an owner holds, without reading any of it", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "a")
      :ok = WardrikVault.put(vault(), "git_hub key", ns(user), value: "b")

      assert Enum.sort(WardrikVault.names(vault(), ns(user))) == ["git_hub key", "github"]
    end

    test "list every credential, with each owner written as text", %{user: user} do
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "#{user}_TOKEN", Resource.deployment(), value: "a")
      :ok = WardrikVault.put(vault(), "linear", ns(org), value: "b")
      :ok = WardrikVault.put(vault(), "github", person(org, user), value: "c", kind: :grant)

      listed = WardrikVault.list(vault())

      assert {"#{user}_TOKEN", Resource.deployment()} in listed
      assert {"linear", ns(org)} in listed
      assert {"github", person(org, user)} in listed
    end

    test "forgetting removes one, and forgetting twice is still fine", %{user: user} do
      :ok = WardrikVault.put(vault(), "github", ns(user), value: "a")

      assert :ok = WardrikVault.forget(vault(), "github", ns(user))
      assert :ok = WardrikVault.forget(vault(), "github", ns(user))
      assert {:error, :not_found} = WardrikVault.fetch(vault(), "github", ns(user))
      refute WardrikVault.has?(vault(), "github", ns(user))
    end
  end

  describe "held_by/3" do
    test "is the owner's own, and never their org's", %{user: user} do
      org = "org-#{user}"
      :ok = WardrikVault.put(vault(), "github", ns(org), value: "org-token", kind: :grant)

      assert WardrikVault.held_by(vault(), "github", ns(org)) == :own
      assert WardrikVault.held_by(vault(), "github", person(org, user)) == :none

      :ok = WardrikVault.put(vault(), "github", person(org, user), value: "user-token")
      assert WardrikVault.held_by(vault(), "github", person(org, user)) == :own
    end

    test "is shared where the owner holds none and a call would find the deployment's",
         %{user: user} do
      sealed = "linear-#{user}"
      granted = "github-#{user}"
      variable = environment_variable("from-the-environment")
      :ok = WardrikVault.put(vault(), sealed, Resource.deployment(), value: "deployment")
      :ok = WardrikVault.put(vault(), granted, Resource.deployment(), value: "t", kind: :grant)

      assert WardrikVault.held_by(vault(), sealed, person("acme", user)) == :none

      Process.put(:vault, %{vault() | shared: [sealed, granted, variable, "unset-#{user}"]})

      assert WardrikVault.held_by(vault(), sealed, person("acme", user)) == :shared
      assert WardrikVault.held_by(vault(), variable, ns("acme")) == :shared
      assert WardrikVault.held_by(vault(), granted, ns("acme")) == :none
      assert WardrikVault.held_by(vault(), "unset-#{user}", ns("acme")) == :none
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
      :ok = WardrikVault.put(vault, "XAI_API_KEY", Resource.deployment(), value: "xai-vault")
      on_exit(fn -> WardrikVault.forget(vault, "XAI_API_KEY", Resource.deployment()) end)

      assert Wardrik.Credentials.key(vault(), "XAI_API_KEY") == {:ok, "xai-vault"}
      assert Wardrik.Credentials.key(vault(), "NOBODY_SEALED_THIS") == :error
    end

    test "grants nothing without grants of its own", %{user: user} do
      none = %WardrikVault.Grants.None{}

      refute WardrikVault.Grants.grants?(none, "github", ns("acme"))

      assert WardrikVault.Grants.renew(none, "github", ns(user), vault: vault(), value: "t") ==
               {:error, :not_found}

      assert WardrikVault.Grants.ask(none, "github", ns(user), vault: vault()) ==
               {:error, :not_found}

      assert WardrikVault.Grants.refused(none, "github", ns(user), vault: vault()) == :ok
    end

    test "tells its grants of a refusal through the host's credentials", %{user: user} do
      grants(%Grants{})
      :ok = WardrikVault.put(vault(), "github", person("acme", user), value: "t", kind: :grant)

      assert Wardrik.Credential.refused(call(org: "acme", user: user), "github") == :ok
      assert_received {:refused, owner}
      assert owner == person("acme", user)
    end
  end
end
