defmodule TarsTUI.SSHTest do
  use ExUnit.Case, async: false

  alias Tars.Fleet

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
    key = Fleet.key("first", org: org)
    {:ok, _pid} = Fleet.spawn(key)
    on_exit(fn -> Fleet.forget_under(org <> "/") end)
    Tars.Test.Fleet.await_update(fn -> Enum.any?(Fleet.list(), &(&1.key == key)) end)

    [first | _rest] = Enum.sort_by(Fleet.list(), & &1.key)

    {:ok, pid} = TarsTUI.SSH.start_link(session: session(self()))
    on_exit(fn -> if Process.alive?(pid), do: Breeze.Server.stop(pid) end)

    assert drawn(first.key) =~ first.key
  end

  test "choose/2 opens on the first agent by key, or starts one for whoever connected" do
    members =
      for key <- ["b/_/two", "a/_/one"],
          do: %Fleet.Member{
            key: key,
            pid: self(),
            node: node(),
            org: nil,
            user: nil,
            name: "x",
            status: :idle,
            pending: 0,
            waiting_on: []
          }

    assert TarsTUI.SSH.choose(members, "jon") == {:attach, "a/_/one"}
    assert TarsTUI.SSH.choose([], ~c"jon") == {:start, "_/jon/assistant"}
  end

  test "copying goes to the client's clipboard, as OSC 52" do
    copy = TarsTUI.Clipboard.osc52(&send(self(), {:written, &1}))

    assert :ok = copy.("hello")
    assert_received {:written, "\e]52;c;aGVsbG8=\a"}
  end
end
