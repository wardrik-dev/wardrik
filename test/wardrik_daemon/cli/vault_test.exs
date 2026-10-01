defmodule WardrikDaemon.CLI.VaultTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias WardrikDaemon.CLI
  alias WardrikDaemon.VaultKey

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = {Application.get_env(:wardrik, WardrikVault), System.get_env("WARDRIK_DATA_HOME")}
    Application.put_env(:wardrik, WardrikVault, keys: [WardrikVault.generate_key()])
    System.put_env("WARDRIK_DATA_HOME", dir)

    on_exit(fn ->
      case previous do
        {nil, _home} -> Application.delete_env(:wardrik, WardrikVault)
        {settings, _home} -> Application.put_env(:wardrik, WardrikVault, settings)
      end

      case previous do
        {_settings, nil} -> System.delete_env("WARDRIK_DATA_HOME")
        {_settings, home} -> System.put_env("WARDRIK_DATA_HOME", home)
      end
    end)

    %{name: "TOKEN_#{System.unique_integer([:positive])}"}
  end

  # Runs a command as over erl_call, answering what it printed and how it
  # exited: 0, 1, or :live for one that needs the terminal it came from.
  defp command(args), do: run(&CLI.main/1, args, "")

  # Runs a command live from a terminal someone types `input` into, or, with
  # `piped: true`, with `input` on standard input.
  defp live(args, input, opts \\ []) do
    terminal =
      if opts[:piped], do: "--terminal=80,plain,no-input", else: "--terminal=80,plain,input"

    run(&CLI.live/1, [terminal | args], input)
  end

  defp run(entry, args, input) do
    parent = self()

    output =
      capture_io(input, fn ->
        try do
          entry.(args)
          send(parent, {:status, 0})
        catch
          :exit, {:shutdown, code} -> send(parent, {:status, code})
        end
      end)

    assert_receive {:status, status}
    {output, status}
  end

  defp no_key, do: Application.delete_env(:wardrik, WardrikVault)

  describe "vault put" do
    test "seals each NAME=VALUE as the deployment's", %{name: name} do
      assert command(["vault", "put", "#{name}=one", "#{name}_B=two=three"]) ==
               {"Sealed #{name}.\nSealed #{name}_B.\n", 0}

      assert WardrikVault.fetch({:named, name}, nil) == {:ok, "one"}
      assert WardrikVault.fetch({:named, name <> "_B"}, nil) == {:ok, "two=three"}
    end

    test "seals for an org, or for a user within one", %{name: name} do
      assert command(["vault", "put", "#{name}=org's", "--org", "acme"]) ==
               {"Sealed #{name} for acme.\n", 0}

      assert command(["vault", "put", "#{name}=jon's", "--org", "acme", "--user", "jon"]) ==
               {"Sealed #{name} for acme/@jon.\n", 0}

      assert command(["vault", "put", "#{name}=none's", "--user", "jon"]) ==
               {"Sealed #{name} for @jon.\n", 0}

      assert WardrikVault.fetch({:org, name}, "acme") == {:ok, "org's"}
      assert WardrikVault.fetch({:user, name}, {"acme", "jon"}) == {:ok, "jon's"}
      assert WardrikVault.fetch({:user, name}, {nil, "jon"}) == {:ok, "none's"}
    end

    test "says where the daemon's environment sets the name too", %{name: name} do
      System.put_env(name, "from the environment")
      on_exit(fn -> System.delete_env(name) end)

      assert command(["vault", "put", "#{name}=sealed"]) ==
               {"Sealed #{name}. The daemon's environment sets #{name} too, " <>
                  "and ${#{name}} reads that one.\n", 0}
    end

    test "asks for a value it is not given, live, and never shows it", %{name: name} do
      assert command(["vault", "put", name]) == {"", :live}

      {output, 0} = live(["vault", "put", name], "s3cret\n")

      assert output == "#{name}, which is not shown as you type: Sealed #{name}.\n"
      assert WardrikVault.fetch({:named, name}, nil) == {:ok, "s3cret"}

      assert live(["vault", "put", name], "\n") ==
               {"#{name}, which is not shown as you type: Nothing was sealed.\n", 0}
    end

    test "reads a value piped in, less the line ending it ends with", %{name: name} do
      assert live(["vault", "put", name], "piped\n", piped: true) == {"Sealed #{name}.\n", 0}
      assert WardrikVault.fetch({:named, name}, nil) == {:ok, "piped"}

      assert live(["vault", "put", name], "two\nlines\r\n", piped: true) ==
               {"Sealed #{name}.\n", 0}

      assert WardrikVault.fetch({:named, name}, nil) == {:ok, "two\nlines"}

      assert {"Nothing came on standard input to seal. Pipe the value in" <> _how, 1} =
               live(["vault", "put", name], "", piped: true)
    end

    test "refuses what it cannot read", %{name: name} do
      assert {"wardrik vault put asks for one value at a time" <> _rest, 1} =
               command(["vault", "put", name, "#{name}_B"])

      assert {"wardrik vault put asks for one value at a time" <> _rest, 1} =
               command(["vault", "put", "=value"])

      assert command(["vault", "put", "#{name}="]) ==
               {"#{name}= gives no value; wardrik vault put #{name} asks for it\n", 1}

      assert command(["vault", "put", "#{name}=v", "--user", "acme/jon"]) ==
               {"--user acme/jon is not a user's name: a name holds no / or whitespace, and " <>
                  "does not begin with @ or _. A user within an org is --org ORG --user USER.\n",
                1}

      for org <- ["_", "@acme", "ac me", ".."] do
        assert {"--org " <> _rest, 1} = command(["vault", "put", "#{name}=v", "--org", org])
      end
    end

    test "says why a secret was not sealed", %{name: name} do
      Mimic.stub(Wardrik.Store, :put, fn _ns, _key, _value -> {:error, :no_quorum} end)

      assert command(["vault", "put", "#{name}=v"]) ==
               {"#{name} was not sealed: :no_quorum\n", 1}
    end
  end

  describe "vault put without a key" do
    setup do
      no_key()
    end

    test "asks to make one, and seals with it", %{name: name, tmp_dir: dir} do
      assert command(["vault", "put", "#{name}=v"]) == {"", :live}

      {output, 0} = live(["vault", "put", "#{name}=v"], "\n")

      assert output =~ "The vault has no key.\n"
      assert output =~ "It is kept in #{dir}/vault_key, beside the store"
      assert output =~ "openssl rand -base64 32 > #{dir}/vault_key"
      assert output =~ "WARDRIK_VAULT_KEY in the daemon's environment"
      assert output =~ "Make one? [Yn]: Made a vault key, in #{dir}/vault_key.\nSealed #{name}.\n"

      assert File.stat!(Path.join(dir, "vault_key")).mode |> Bitwise.band(0o777) == 0o600
      assert WardrikVault.fetch({:named, name}, nil) == {:ok, "v"}

      assert command(["vault", "put", "#{name}=again"]) == {"Sealed #{name}.\n", 0}
    end

    test "makes it before asking for the value", %{name: name} do
      {output, 0} = live(["vault", "put", name], "y\ntyped\n")

      assert output =~
               "Made a vault key, in #{VaultKey.file()}.\n" <>
                 "#{name}, which is not shown as you type: Sealed #{name}.\n"
    end

    test "makes none where told not to", %{name: name, tmp_dir: dir} do
      {output, 0} = live(["vault", "put", "#{name}=v"], "n\n")

      assert output =~ "Make one? [Yn]: Nothing was sealed.\n"
      refute File.exists?(Path.join(dir, "vault_key"))
    end

    test "makes one with --yes, without asking", %{name: name, tmp_dir: dir} do
      assert command(["vault", "put", "#{name}=v", "--yes"]) ==
               {"Made a vault key, in #{dir}/vault_key.\nSealed #{name}.\n", 0}
    end

    test "says how to give it one where no one can answer", %{name: name} do
      {output, 1} = live(["vault", "put", name], "piped\n", piped: true)

      assert output =~ "The vault has no key, and wardrik vault put --yes makes one.\n"
      assert output =~ "To set one instead: WARDRIK_VAULT_KEY"
      refute WardrikVault.Config.configured?()
    end

    test "reads a key file written since the daemon started", %{name: name, tmp_dir: dir} do
      File.write!(Path.join(dir, "vault_key"), WardrikVault.generate_key())

      assert command(["vault", "put", "#{name}=v"]) == {"Sealed #{name}.\n", 0}
    end

    test "says why a key file holds no key, or a key set is not one", %{name: name, tmp_dir: dir} do
      File.write!(Path.join(dir, "vault_key"), "c2hvcnQ=")

      {output, 1} = command(["vault", "put", "#{name}=v", "--yes"])
      assert output =~ "#{dir}/vault_key holds no key the vault can use"

      Application.put_env(:wardrik, WardrikVault, keys: ["c2hvcnQ="])

      assert {"The vault's key is not one it can use, 32 bytes in base64." <> _how, 1} =
               command(["vault", "put", "#{name}=v"])
    end
  end

  describe "vault ls" do
    test "names each secret and whose it is, never its value", %{name: name} do
      org = "org-#{name}"
      :ok = WardrikVault.put({:named, name}, nil, "deployment-value")
      :ok = WardrikVault.put({:org, name}, org, "org-value")
      :ok = WardrikVault.put({:user, name}, {org, "jon"}, "jon-value")
      :ok = WardrikVault.put({:user, name}, {org, "ann"}, "ann-value")

      {output, 0} = command(["vault", "ls"])

      assert output =~ ~r/^  #{name} +the deployment's$/m
      assert output =~ ~r/^  #{name} +#{org}'s$/m
      assert output =~ ~r/^  #{name} +2 users'$/m
      refute output =~ "-value"

      assert command(["vault", "ls", "--org", org, "--user", "jon"]) ==
               {"1 secret:\n  #{name}  #{org}/@jon's\n", 0}

      assert command(["vault", "ls", "--org", "nobody-#{name}"]) ==
               {"The vault holds no secrets for nobody-#{name}.\n", 0}
    end

    test "marks a name the daemon's environment sets too", %{name: name} do
      :ok = WardrikVault.put({:named, name}, nil, "v")
      System.put_env(name, "set")
      on_exit(fn -> System.delete_env(name) end)

      {output, 0} = command(["vault", "ls"])

      assert output =~ ~r/^  #{name} +the deployment's; the daemon's environment sets it too$/m
    end

    test "says where the vault holds nothing" do
      Mimic.stub(Wardrik.Store, :keys, fn :vault -> [] end)

      assert command(["vault", "ls"]) ==
               {"The vault holds no secrets. wardrik vault put NAME seals one.\n", 0}
    end

    test "answers --json with each secret's name and owner", %{name: name} do
      org = "org-#{name}"
      :ok = WardrikVault.put({:named, name}, nil, "v")
      :ok = WardrikVault.put({:org, name}, org, "v")
      :ok = WardrikVault.put({:user, name}, {org, "jon"}, "v")

      {output, 0} = command(["vault", "ls", "--json"])

      secrets =
        output |> JSON.decode!() |> Map.fetch!("secrets") |> Enum.filter(&(&1["name"] == name))

      assert secrets == [
               %{"name" => name, "kind" => "named", "environment" => false},
               %{"name" => name, "kind" => "org", "owner" => org},
               %{"name" => name, "kind" => "user", "count" => 1}
             ]

      {output, 0} = command(["vault", "ls", "--org", org, "--user", "jon", "--json"])

      assert JSON.decode!(output) == %{
               "secrets" => [
                 %{"name" => name, "kind" => "user", "owner" => "#{org}/@jon"}
               ]
             }
    end
  end

  describe "vault rm" do
    test "removes one secret, of the owner named", %{name: name} do
      :ok = WardrikVault.put({:named, name}, nil, "v")
      :ok = WardrikVault.put({:org, name}, "acme", "v")

      assert command(["vault", "rm", name, "--org", "acme"]) == {"Removed #{name} for acme.\n", 0}
      assert WardrikVault.fetch({:org, name}, "acme") == {:error, :not_found}
      assert WardrikVault.fetch({:named, name}, nil) == {:ok, "v"}

      :ok = WardrikVault.put({:user, name}, {"acme", "jon"}, "v")

      assert command(["vault", "rm", name, "--org", "acme", "--user", "jon"]) ==
               {"Removed #{name} for acme/@jon.\n", 0}

      assert command(["vault", "rm", name]) == {"Removed #{name}.\n", 0}
      assert command(["vault", "rm", name]) == {"The vault holds no #{name}.\n", 1}
    end
  end
end
