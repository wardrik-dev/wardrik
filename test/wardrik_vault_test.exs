defmodule WardrikVaultTest do
  use ExUnit.Case, async: false

  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Scope
  alias Wardrik.Test.Calls
  alias WardrikVault.Sealed

  setup do
    previous = Application.get_env(:wardrik, WardrikVault)
    Application.put_env(:wardrik, WardrikVault, keys: [WardrikVault.generate_key()])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardrik, WardrikVault, previous),
        else: Application.delete_env(:wardrik, WardrikVault)
    end)

    %{user: "jon-#{System.unique_integer([:positive])}"}
  end

  defp scope(opts), do: Config.new() |> Scope.root("acme/jon/assistant", opts)

  defp keys(list), do: Application.put_env(:wardrik, WardrikVault, keys: list)

  describe "path/2" do
    test "writes distinct owners and names under distinct keys" do
      paths =
        for {ref, owner} <- [
              {{:user, "github"}, "jon doe"},
              {{:user, "github"}, "jon_doe"},
              {{:user, "github"}, "jon/doe"},
              {{:user, "github"}, "_"},
              {{:user, "github"}, nil},
              {{:user, "github"}, {"acme", "jon"}},
              {{:user, "github"}, {"globex", "jon"}},
              {{:user, "git hub"}, "jon"},
              {{:user, "git_hub"}, "jon"}
            ] do
          {:ok, path} = WardrikVault.path(ref, owner)
          path
        end

      assert length(Enum.uniq(paths)) == length(paths)
      assert {:ok, "user/jon/github"} = WardrikVault.path({:user, "github"}, "jon")
    end
  end

  describe "put/3 and fetch/2" do
    test "hands back what it was given", %{user: user} do
      assert :ok = WardrikVault.put({:user, "github"}, user, "ghp_secret")

      assert {:ok, "ghp_secret"} = WardrikVault.fetch({:user, "github"}, user)
    end

    test "keeps one owner's secret from another", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "mine")

      assert {:error, :not_found} = WardrikVault.fetch({:user, "github"}, "someone-else")
    end

    test "keeps one name's secret from another", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "mine")

      assert {:error, :not_found} = WardrikVault.fetch({:user, "linear"}, user)
    end

    test "a second put replaces the first", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "old")
      :ok = WardrikVault.put({:user, "github"}, user, "new")

      assert {:ok, "new"} = WardrikVault.fetch({:user, "github"}, user)
    end

    test "an org secret and a named one are their own", %{user: user} do
      :ok = WardrikVault.put({:org, "github"}, "acme", "org-token")
      :ok = WardrikVault.put({:named, "ci"}, nil, "ci-token")

      assert {:ok, "org-token"} = WardrikVault.fetch({:org, "github"}, "acme")
      assert {:ok, "ci-token"} = WardrikVault.fetch({:named, "ci"}, nil)
      assert {:error, :not_found} = WardrikVault.fetch({:user, "github"}, user)
    end
  end

  describe "what is written down" do
    test "is sealed, and says nothing when inspected", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "ghp_secret")
      {:ok, path} = WardrikVault.path({:user, "github"}, user)

      {%Sealed{} = sealed, _vsn} = Wardrik.Store.lookup(WardrikVault.namespace(), path)

      refute inspect(sealed) =~ "ghp_secret"
      refute sealed.ciphertext =~ "ghp_secret"
      assert inspect(sealed) =~ "sealed"
    end

    test "will not unseal under another owner's path", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "ghp_secret")
      {:ok, mine} = WardrikVault.path({:user, "github"}, user)
      {:ok, theirs} = WardrikVault.path({:user, "github"}, "thief")

      {sealed, _vsn} = Wardrik.Store.lookup(WardrikVault.namespace(), mine)
      {:ok, _vsn} = Wardrik.Store.put(WardrikVault.namespace(), theirs, sealed)

      assert {:error, :undecipherable} = WardrikVault.fetch({:user, "github"}, "thief")
    end
  end

  describe "keys" do
    test "a rotated key still reads what the old one sealed", %{user: user} do
      [old] = Application.get_env(:wardrik, WardrikVault)[:keys]
      :ok = WardrikVault.put({:user, "github"}, user, "ghp_secret")

      keys([WardrikVault.generate_key(), old])

      assert {:ok, "ghp_secret"} = WardrikVault.fetch({:user, "github"}, user)
    end

    test "a key that is gone cannot read what it sealed", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "ghp_secret")

      keys([WardrikVault.generate_key()])

      assert {:error, :undecipherable} = WardrikVault.fetch({:user, "github"}, user)
    end

    test "with no key nothing is written and nothing is read", %{user: user} do
      keys([])

      assert {:error, :no_key} = WardrikVault.put({:user, "github"}, user, "ghp_secret")
      assert {:error, :no_key} = WardrikVault.fetch({:user, "github"}, user)
      refute WardrikVault.ready?()
    end

    test "generate_key/0 makes a key the vault accepts" do
      keys([WardrikVault.generate_key()])

      assert WardrikVault.ready?()
    end
  end

  describe "as a Wardrik.Credential resolver" do
    test "resolves a user reference against the scope's user", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "ghp_secret")

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: WardrikVault, user: user)),
                 {:user, "github"}
               )

      assert Credential.reveal(credential) == "ghp_secret"
    end

    test "resolves an org reference against the scope's org" do
      :ok = WardrikVault.put({:org, "github"}, "acme", "org-token")

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: WardrikVault, org: "acme")),
                 {:org, "github"}
               )

      assert Credential.reveal(credential) == "org-token"
    end

    test "a scope with no user cannot resolve a user reference" do
      assert {:error, :no_user} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: WardrikVault)),
                 {:user, "github"}
               )
    end

    test "a secret nobody has put there is not found", %{user: user} do
      assert {:error, :not_found} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: WardrikVault, user: user)),
                 {:user, "nothing"}
               )
    end
  end

  describe "names/2 and forget/2" do
    test "lists what an owner has, without reading any of it", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "a")
      :ok = WardrikVault.put({:user, "linear"}, user, "b")

      assert WardrikVault.names(:user, user) |> Enum.sort() ==
               [{:user, "github"}, {:user, "linear"}]
    end

    test "forgetting removes one, and forgetting twice is still fine", %{user: user} do
      :ok = WardrikVault.put({:user, "github"}, user, "a")

      assert :ok = WardrikVault.forget({:user, "github"}, user)
      assert :ok = WardrikVault.forget({:user, "github"}, user)
      assert {:error, :not_found} = WardrikVault.fetch({:user, "github"}, user)
      refute WardrikVault.has?({:user, "github"}, user)
    end
  end
end
