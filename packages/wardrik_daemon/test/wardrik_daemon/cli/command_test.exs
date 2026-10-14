defmodule WardrikDaemon.CLI.CommandTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.CLI.Command

  defp plain(data), do: data |> WardrikConsole.Ansi.chardata(false) |> IO.chardata_to_string()

  @commands [
    %Command{
      name: "ask",
      group: "Talk to agents",
      arguments: "KEY MESSAGE",
      summary: "send an agent a message",
      count: {2, :any}
    },
    %Command{
      name: "token create",
      group: "Tokens",
      arguments: "NAME",
      options: "[--can ACTIONS]",
      summary: "make a token",
      switches: [can: :string],
      count: {1, 1}
    },
    %Command{
      name: "token list",
      group: "Tokens",
      summary: "list tokens",
      json: &Function.identity/1
    }
  ]

  test "find/2 takes the longest name the arguments open with" do
    assert {:ok, %Command{name: "token create"}, ["dev"]} =
             Command.find(@commands, ["token", "create", "dev"])

    assert {:group, "token", [_create, _list]} = Command.find(@commands, ["token"])
    assert {:unknown, "token lst", ["token list"]} = Command.find(@commands, ["token", "lst"])
    assert {:unknown, "asl", ["ask"]} = Command.find(@commands, ["asl"])
  end

  test "parse/2 reads words and options, and answers the usage where they do not read" do
    [ask, create, list] = @commands

    assert Command.parse(ask, ["acme/triage", "what", "changed"]) ==
             {:ok, ["acme/triage", "what", "changed"], []}

    assert Command.parse(create, ["dev", "--can", "read"]) == {:ok, ["dev"], [can: "read"]}
    assert Command.parse(list, ["--json"]) == {:ok, [], [json: true]}

    assert {:error, usage} = Command.parse(ask, ["acme/triage"])
    assert plain(usage) == "Usage: wardrik ask KEY MESSAGE"

    assert {:error, usage} = Command.parse(create, ["dev", "--json"])
    assert plain(usage) =~ "wardrik token create takes no option --json"
  end

  test "usage/1 adds --json to a command that answers with it" do
    [_ask, create, list] = @commands

    assert plain(Command.usage(create)) == "Usage: wardrik token create NAME [--can ACTIONS]"
    assert plain(Command.usage(list)) == "Usage: wardrik token list [--json]"
  end

  test "listing/2 lines summaries up where the width has room, and puts them under where not" do
    assert plain(Command.listing(@commands, 80)) ==
             Enum.join(
               [
                 "  ask KEY MESSAGE    send an agent a message",
                 "  token create NAME  make a token",
                 "  token list         list tokens"
               ],
               "\n"
             )

    assert plain(Command.listing(Enum.take(@commands, 1), 30)) ==
             "  ask KEY MESSAGE\n      send an agent a message"
  end

  test "grouped/2 lists each group under its heading, with one column for them all" do
    assert plain(Command.grouped(@commands, 80)) ==
             Enum.join(
               [
                 "Talk to agents:",
                 "  ask KEY MESSAGE    send an agent a message",
                 "",
                 "Tokens:",
                 "  token create NAME  make a token",
                 "  token list         list tokens"
               ],
               "\n"
             )
  end
end
