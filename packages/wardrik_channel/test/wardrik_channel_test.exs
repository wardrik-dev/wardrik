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
        {WardrikChannel.Supervisor,
         channels:
           WardrikChannel.channels([one: {WardrikChannel.Test.Adapter, settings}],
             host: Wardrik.Host.new(store: Wardrik.Test.store())
           )}
      )

    assert [{_tasks, _task_pid, :supervisor, _}, {{:channel, "one"}, channel, :worker, _}] =
             pid |> Supervisor.which_children() |> Enum.sort()

    assert Agent.get(channel, & &1)[:name] == "one"
    assert %WardrikChannel.Context{channel: "one"} = Agent.get(channel, & &1)[:context]
  end

  test "knows someone by the channel and the id it knows them by, among those named" do
    named = {WardrikChannel.Test.Adapter, test: self()}

    assert WardrikChannel.person(WardrikChannel.principal(:named, "U1", "maria")) ==
             {"named", "U1"}

    assert WardrikChannel.among?(named, "U1", ["U2", "U1"])
    refute WardrikChannel.among?(named, "U1", ["U2"])
    refute WardrikChannel.among?(named, "U1", [])
  end

  test "makes each channel's context once, from the host's answers" do
    host = Wardrik.Host.new(store: Wardrik.Test.store())

    assert %{"one" => {WardrikChannel.Test.Adapter, [test: :me], context}} =
             WardrikChannel.channels([one: {WardrikChannel.Test.Adapter, test: :me}],
               host: host,
               replies: :elsewhere
             )

    assert %WardrikChannel.Context{channel: "one", host: ^host, replies: :elsewhere} = context
  end

  test "runs what each channel runs, under its name, beside the channels' tasks" do
    {:ok, {_flags, [tasks | channels]}} =
      WardrikChannel.Supervisor.init(
        channels:
          WardrikChannel.channels(
            [
              one: {WardrikChannel.Test.Adapter, test: self()},
              two: {WardrikChannel.Test.Adapter, test: self()}
            ],
            host: Wardrik.Host.new(store: Wardrik.Test.store())
          )
      )

    assert tasks.id == WardrikChannel.tasks()

    assert [
             %{id: {:channel, "one"}, start: {Agent, :start_link, [one]}},
             %{id: {:channel, "two"}}
           ] =
             Enum.sort_by(channels, & &1.id)

    assert one.()[:name] == "one"
  end
end
