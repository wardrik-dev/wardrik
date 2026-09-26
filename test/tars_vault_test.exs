defmodule TarsVaultTest do
  use ExUnit.Case, async: false

  alias Tars.Credential
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.Calls
  alias TarsVault.Sealed

  setup do
    previous = Application.get_env(:tars, TarsVault)
    Application.put_env(:tars, TarsVault, keys: [TarsVault.generate_key()])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tars, TarsVault, previous),
        else: Application.delete_env(:tars, TarsVault)
    end)

    %{user: "jon-#{System.unique_integer([:positive])}"}
  end

  defp scope(opts), do: Config.new() |> Scope.root("acme/jon/assistant", opts)

  defp keys(list), do: Application.put_env(:tars, TarsVault, keys: list)

  describe "put/3 and fetch/2" do
    test "hands back what it was given", %{user: user} do
      assert :ok = TarsVault.put({:user, "github"}, user, "ghp_secret")

      assert {:ok, "ghp_secret"} = TarsVault.fetch({:user, "github"}, user)
    end

    test "keeps one owner's secret from another", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "mine")

      assert {:error, :not_found} = TarsVault.fetch({:user, "github"}, "someone-else")
    end

    test "keeps one name's secret from another", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "mine")

      assert {:error, :not_found} = TarsVault.fetch({:user, "linear"}, user)
    end

    test "a second put replaces the first", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "old")
      :ok = TarsVault.put({:user, "github"}, user, "new")

      assert {:ok, "new"} = TarsVault.fetch({:user, "github"}, user)
    end

    test "an org secret and a named one are their own", %{user: user} do
      :ok = TarsVault.put({:org, "github"}, "acme", "org-token")
      :ok = TarsVault.put({:named, "ci"}, nil, "ci-token")

      assert {:ok, "org-token"} = TarsVault.fetch({:org, "github"}, "acme")
      assert {:ok, "ci-token"} = TarsVault.fetch({:named, "ci"}, nil)
      assert {:error, :not_found} = TarsVault.fetch({:user, "github"}, user)
    end
  end

  describe "what is written down" do
    test "is sealed, and says nothing when inspected", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "ghp_secret")
      {:ok, path} = TarsVault.path({:user, "github"}, user)

      {%Sealed{} = sealed, _vsn} = Tars.Store.lookup(TarsVault.namespace(), path)

      refute inspect(sealed) =~ "ghp_secret"
      refute sealed.ciphertext =~ "ghp_secret"
      assert inspect(sealed) =~ "sealed"
    end

    test "will not unseal under another owner's path", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "ghp_secret")
      {:ok, mine} = TarsVault.path({:user, "github"}, user)
      {:ok, theirs} = TarsVault.path({:user, "github"}, "thief")

      {sealed, _vsn} = Tars.Store.lookup(TarsVault.namespace(), mine)
      {:ok, _vsn} = Tars.Store.put(TarsVault.namespace(), theirs, sealed)

      assert {:error, :undecipherable} = TarsVault.fetch({:user, "github"}, "thief")
    end
  end

  describe "keys" do
    test "a rotated key still reads what the old one sealed", %{user: user} do
      [old] = Application.get_env(:tars, TarsVault)[:keys]
      :ok = TarsVault.put({:user, "github"}, user, "ghp_secret")

      keys([TarsVault.generate_key(), old])

      assert {:ok, "ghp_secret"} = TarsVault.fetch({:user, "github"}, user)
    end

    test "a key that is gone cannot read what it sealed", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "ghp_secret")

      keys([TarsVault.generate_key()])

      assert {:error, :undecipherable} = TarsVault.fetch({:user, "github"}, user)
    end

    test "with no key nothing is written and nothing is read", %{user: user} do
      keys([])

      assert {:error, :no_key} = TarsVault.put({:user, "github"}, user, "ghp_secret")
      assert {:error, :no_key} = TarsVault.fetch({:user, "github"}, user)
      refute TarsVault.ready?()
    end

    test "generate_key/0 makes a key the vault accepts" do
      keys([TarsVault.generate_key()])

      assert TarsVault.ready?()
    end
  end

  describe "as a Tars.Credential resolver" do
    test "resolves a user reference against the scope's user", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "ghp_secret")

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: TarsVault, user: user)),
                 {:user, "github"}
               )

      assert Credential.reveal(credential) == "ghp_secret"
    end

    test "resolves an org reference against the scope's org" do
      :ok = TarsVault.put({:org, "github"}, "acme", "org-token")

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: TarsVault, org: "acme")),
                 {:org, "github"}
               )

      assert Credential.reveal(credential) == "org-token"
    end

    test "a scope with no user cannot resolve a user reference" do
      assert {:error, :no_user} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: TarsVault)),
                 {:user, "github"}
               )
    end

    test "a secret nobody has put there is not found", %{user: user} do
      assert {:error, :not_found} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(credentials: TarsVault, user: user)),
                 {:user, "nothing"}
               )
    end
  end

  describe "names/2 and forget/2" do
    test "lists what an owner has, without reading any of it", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "a")
      :ok = TarsVault.put({:user, "linear"}, user, "b")

      assert TarsVault.names(:user, user) |> Enum.sort() ==
               [{:user, "github"}, {:user, "linear"}]
    end

    test "forgetting removes one, and forgetting twice is still fine", %{user: user} do
      :ok = TarsVault.put({:user, "github"}, user, "a")

      assert :ok = TarsVault.forget({:user, "github"}, user)
      assert :ok = TarsVault.forget({:user, "github"}, user)
      assert {:error, :not_found} = TarsVault.fetch({:user, "github"}, user)
      refute TarsVault.has?({:user, "github"}, user)
    end
  end
end
