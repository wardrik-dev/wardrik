defmodule WardrikDaemon.CLI.CompletionTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.CLI
  alias WardrikDaemon.CLI.Completion

  # Two agents running, one waiting on two calls.
  defp known do
    %{
      keys: fn -> ["acme/triage", "acme/@jon/digest"] end,
      calls: fn
        "acme/triage" -> ["call_1", "call_2"]
        _key -> []
      end
    }
  end

  defp complete(words), do: Completion.candidates(words, CLI.commands(), known())

  test "a first word is a command's, each once" do
    names = complete([""])

    assert "status" in names
    assert "token" in names
    assert names == Enum.uniq(names)
    assert complete(["st"]) == ["start", "stop", "status"]
    assert complete([]) == complete([""])
  end

  test "a group's second word is one of its commands'" do
    assert complete(["token", ""]) == ["create", "list", "revoke"]
    assert complete(["service", "u"]) == ["uninstall", "unit"]
  end

  test "an option is one the command takes, --json where it answers with JSON" do
    assert complete(["token", "create", "dev", "--"]) ==
             ~w(--scope --all --can --policy --unlimited --help)

    assert complete(["history", "--j"]) == ["--json"]
    assert complete(["ask", "acme/triage", "--no"]) == ["--no-wait"]
  end

  test "a KEY is a running agent's, and a CALL one that agent waits on" do
    assert complete(["show", "acme/@j"]) == ["acme/@jon/digest"]
    assert complete(["approve", ""]) == ["acme/triage", "acme/@jon/digest"]
    assert complete(["approve", "acme/triage", ""]) == ["call_1", "call_2"]
    assert complete(["deny", "acme/@jon/digest", ""]) == []
    assert complete(["schedules", "acme/"]) == ["acme/triage", "acme/@jon/digest"]
  end

  test "a query takes its words and agents' keys, as many as it is given" do
    assert complete(["ls", "status:"]) == ~w(status:idle status:running status:parked)
    assert complete(["ls", "status:parked", "acme/t"]) == ["acme/triage"]
  end

  test "a word an option is waiting for, or one past the last a command takes, has nothing" do
    assert complete(["token", "create", "dev", "--scope", ""]) == []
    assert complete(["show", "acme/triage", ""]) == []
    assert complete(["status", ""]) == []
  end

  test "help completes command names, and --node is passed over" do
    assert complete(["help", "tok"]) == ["token"]
    assert complete(["help", "token", "c"]) == ["create"]
    assert complete(["--node", "a", "sta"]) == ["start", "status"]
    assert complete(["--node=a", "sta"]) == ["start", "status"]
    assert complete(["completion", ""]) == ~w(bash zsh fish)
  end

  test "each shell's script asks __complete, for wardrik and rik alike" do
    for shell <- Completion.shells() do
      script = Completion.script(shell)
      assert script =~ "__complete"
      assert script =~ "wardrik"
      assert script =~ "rik"
    end
  end
end
