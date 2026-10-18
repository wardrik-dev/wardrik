defmodule WardrikTUI.SSHTest do
  use ExUnit.Case, async: false

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.AgentID
  alias Wardrik.Fleet

  # Answers termite's terminal requests the way an SSH channel does, and hands
  # the test everything written to it.
  defp channel(test_pid) do
    spawn_link(fn -> serve(test_pid) end)
  end

  defp serve(test_pid) do
    receive do
      {:terminal_request, from, ref, {:attach_terminal, _target, _reader}} ->
        reply(from, ref, :ok)

      {:terminal_request, from, ref, {:write, data}} ->
        send(test_pid, {:written, IO.iodata_to_binary(data)}) && reply(from, ref, :ok)

      {:terminal_request, from, ref, :size} ->
        reply(from, ref, {:ok, {120, 30}})

      {:terminal_request, from, ref, _other} ->
        reply(from, ref, :ok)
    end

    serve(test_pid)
  end

  defp reply(from, ref, reply), do: send(from, {:terminal_reply, ref, reply})

  defp session(test_pid),
    do: %Termite.SSH.Session{username: "jon", channel_pid: channel(test_pid)}

  # What the TUI has written to the channel, as soon as it holds `text`.
  defp drawn(text, acc \\ "") do
    if acc =~ text do
      acc
    else
      receive do
        {:written, data} -> drawn(text, acc <> data)
      after
        5_000 -> acc
      end
    end
  end

  test "a session draws the TUI on the channel, on the first agent the fleet runs" do
    org = "aaa-ssh-#{System.unique_integer([:positive])}"
    id = AgentID.new!("first", org: org)
    {:ok, _pid} = Fleet.spawn(id)
    on_exit(fn -> Fleet.forget_under(AgentID.Prefix.new!(org: org)) end)

    Wardrik.Test.Fleet.await_update(fn ->
      Enum.any?(
        Fleet.list(Wardrik.AgentID.Prefix.all(), host: Wardrik.Test.host()),
        &(&1.id == id)
      )
    end)

    [first | _rest] = Fleet.list(Wardrik.AgentID.Prefix.all(), host: Wardrik.Test.host())

    {:ok, pid} =
      WardrikTUI.SSH.start_link(
        session: session(self()),
        org: "default",
        host: Wardrik.Host.new(store: Wardrik.Test.store())
      )

    on_exit(fn -> if Process.alive?(pid), do: Breeze.Server.stop(pid) end)

    assert drawn(to_string(first.id)) =~ to_string(first.id)
  end

  test "choose/3 opens on the first agent by ID, or starts one for whoever connected" do
    members =
      for id <- [~A"b/two", ~A"a/one"],
          do: %Fleet.Member{
            id: id,
            pid: self(),
            node: node(),
            status: :idle,
            pending: 0,
            waiting_on: []
          }

    assert WardrikTUI.SSH.choose(members, "jon", nil) == {:attach, ~A"a/one"}
    assert WardrikTUI.SSH.choose([], ~c"jon", "default") == {:start, ~A"default/@jon/assistant"}
    assert WardrikTUI.SSH.choose([], "_build", "default") == {:start, ~A"default/assistant"}
    assert {:error, "an agent's org is missing"} = WardrikTUI.SSH.choose([], "jon", nil)
  end

  test "copying goes to the client's clipboard, as OSC 52" do
    copy = WardrikTUI.Clipboard.osc52(&send(self(), {:written, &1}))

    assert :ok = copy.("hello")
    assert_received {:written, "\e]52;c;aGVsbG8=\a"}
  end
end
