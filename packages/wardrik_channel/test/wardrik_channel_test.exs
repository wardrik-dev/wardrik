defmodule WardrikChannelTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias WardrikChannel.Channel
  alias WardrikChannel.Installation
  alias WardrikChannel.Installations
  alias WardrikChannel.Outbound
  alias WardrikChannel.Response
  alias WardrikNotify.Notice

  defp installation,
    do: %Installation{channel: "named", workspace: "T1", owner: Prefix.all(), token: "token"}

  defp host, do: Wardrik.Host.new(store: Wardrik.Test.store())

  defp notice,
    do: %Notice{
      agent: Wardrik.AgentID.parse!("acme/triage"),
      kind: :failed,
      at: DateTime.utc_now()
    }

  test "finds an adapter by the type its application names" do
    assert WardrikChannel.discover()["test"] == WardrikChannel.Test.Adapter
    refute Map.has_key?(WardrikChannel.discover(), "carrier-pigeon")
  end

  test "posts a notice in a room through the channel's adapter" do
    notice = notice()
    installation = installation()

    opts = [
      channel: {WardrikChannel.Test.Adapter, test: self()},
      installation: installation,
      room: "#ops",
      approvers: ["@maria"],
      req_options: [retry: false]
    ]

    assert :ok = WardrikChannel.Notices.deliver(notice, opts)

    assert_received {:delivered,
                     %Outbound{
                       installation: ^installation,
                       room: "#ops",
                       body: {:notice, ^notice},
                       approvers: ["@maria"]
                     }, channel}

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
             host: host(),
             installations: Installations.Config.new([])
           )}
      )

    assert [{_tasks, _task_pid, :supervisor, _}, {{:channel, "one"}, channel, :worker, _}] =
             pid |> Supervisor.which_children() |> Enum.sort()

    assert Agent.get(channel, & &1)[:name] == "one"
    assert %WardrikChannel.Context{channel: "one"} = Agent.get(channel, & &1)[:context]
  end

  test "knows someone by the channel, the workspace and the id it knows them by" do
    named = {WardrikChannel.Test.Adapter, test: self()}
    maria = WardrikChannel.principal(installation(), "U1", "maria")

    assert Wardrik.Principal.id(maria) == "named/T1/U1"
    assert WardrikChannel.person(maria) == {"named", "T1", "U1"}

    assert WardrikChannel.among?(named, installation(), "U1", ["U2", "U1"])
    refute WardrikChannel.among?(named, installation(), "U1", ["U2"])
    refute WardrikChannel.among?(named, installation(), "U1", [])
  end

  test "makes each channel once, its context from the host's answers" do
    host = host()
    installations = Installations.Config.new([])

    assert %{
             "one" => %Channel{
               name: "one",
               adapter: WardrikChannel.Test.Adapter,
               options: [test: :me],
               context: context
             }
           } =
             WardrikChannel.channels([one: {WardrikChannel.Test.Adapter, test: :me}],
               host: host,
               installations: installations,
               replies: :elsewhere
             )

    assert %WardrikChannel.Context{
             channel: "one",
             host: ^host,
             installations: ^installations,
             replies: :elsewhere
           } = context
  end

  test "hands a request the medium sent to the channel's adapter, as it was sent" do
    %{"one" => channel} =
      WardrikChannel.channels([one: {WardrikChannel.Test.Adapter, test: self()}],
        host: host(),
        installations: Installations.Config.new([])
      )

    assert %Response{status: 200, body: body} =
             WardrikChannel.request(channel, %{
               method: "POST",
               path: ["events"],
               headers: [{"x-signature", "v0=abc"}],
               body: ~s({"a":1})
             })

    assert JSON.decode!(body) == %{"path" => ["events"], "body" => ~s({"a":1})}
    assert_received {:request, request, opts}
    assert WardrikChannel.Request.header(request, "x-signature") == "v0=abc"
    assert WardrikChannel.Request.header(request, "x-other") == nil
    assert request.query == %{}
    assert opts[:name] == "one"
    assert %WardrikChannel.Context{channel: "one"} = opts[:context]
  end

  test "installs a channel for an owner, where its host keeps installations" do
    installations = %WardrikChannel.Test.Installations{
      agent: start_supervised!({Agent, fn -> %{} end})
    }

    %{"one" => channel} =
      WardrikChannel.channels([one: {WardrikChannel.Test.Adapter, test: self()}],
        host: host(),
        installations: installations
      )

    acme = Prefix.new!(org: "acme")

    assert {:ok, "https://chat.example/install?owner=acme/&return_to=/settings"} =
             WardrikChannel.install_url(channel, acme, return_to: "/settings")

    assert %Response{status: 302} =
             WardrikChannel.install(channel, acme, %{
               method: "GET",
               path: ["install"],
               query: %{"workspace" => "T7"},
               headers: [],
               body: ""
             })

    assert {:ok, %Installation{owner: ^acme, token: "token-T7"}} =
             Installations.fetch(installations, "one", "T7")
  end

  test "installs nothing more than its config names, from its config" do
    config = Installations.Config.new([{:slack, "xoxb-1", Prefix.all()}])

    assert {:ok, %Installation{channel: "slack", workspace: "slack", token: "xoxb-1"}} =
             Installations.fetch(config, "slack", "T0123")

    assert :error = Installations.fetch(config, "other", "T0123")
    assert {:error, _why} = Installations.put(config, %{installation() | channel: "slack"})
    assert :ok = Installations.delete(config, "slack", "slack")
    assert {:ok, _still} = Installations.fetch(config, "slack", "slack")
    refute inspect(installation()) =~ "token"
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
            host: host(),
            installations: Installations.Config.new([])
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
