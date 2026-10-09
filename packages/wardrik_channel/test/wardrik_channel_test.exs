defmodule WardrikChannelTest do
  use ExUnit.Case, async: true

  alias WardrikChannel.Outbound
  alias WardrikNotify.Notice

  defp notice,
    do: %Notice{
      agent: Wardrik.AgentID.parse!("acme/triage"),
      kind: :failed,
      at: DateTime.utc_now()
    }

  test "finds an adapter by the type its application names" do
    assert WardrikChannel.adapters()["test"] == WardrikChannel.Test.Adapter
    assert WardrikChannel.adapter("test") == {:ok, WardrikChannel.Test.Adapter}
    assert WardrikChannel.adapter("carrier-pigeon") == :error
  end

  test "posts a notice in a room through the channel's adapter" do
    notice = notice()

    opts = [
      channel: {WardrikChannel.Test.Adapter, test: self()},
      room: "#ops",
      approvers: ["@maria"],
      req_options: [retry: false]
    ]

    assert :ok = WardrikChannel.Notices.deliver(notice, opts)

    assert_received {:delivered,
                     %Outbound{room: "#ops", body: {:notice, ^notice}, approvers: ["@maria"]},
                     channel}

    assert channel[:test] == self()
    assert channel[:req_options] == [retry: false]

    assert {:error, :no_room} =
             WardrikChannel.Notices.deliver(notice, Keyword.put(opts, :room, "#nowhere"))
  end

  test "starts each channel's own, under its name" do
    test = self()
    {:ok, settings} = WardrikChannel.Test.Adapter.config(%{"test" => test})
    assert {:error, ["test"], _why} = WardrikChannel.Test.Adapter.config(%{})

    pid =
      start_supervised!(
        {WardrikChannel.Supervisor, channels: [one: {WardrikChannel.Test.Adapter, settings}]}
      )

    assert [{_tasks, _task_pid, :supervisor, _}, {{:channel, :one}, channel, :worker, _}] =
             pid |> Supervisor.which_children() |> Enum.sort()

    assert Agent.get(channel, & &1)[:name] == :one
  end

  test "runs what each channel runs, under its name, beside the channels' tasks" do
    {:ok, {_flags, [tasks | channels]}} =
      WardrikChannel.Supervisor.init(
        channels: [
          one: {WardrikChannel.Test.Adapter, test: self()},
          two: {WardrikChannel.Test.Adapter, test: self()}
        ]
      )

    assert tasks.id == WardrikChannel.tasks()

    assert [%{id: {:channel, :one}, start: {Agent, :start_link, [one]}}, %{id: {:channel, :two}}] =
             channels

    assert one.()[:name] == :one
  end
end
