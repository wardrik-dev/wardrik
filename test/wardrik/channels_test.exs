defmodule Wardrik.Test.Echo do
  @moduledoc "A channel that tells the test it started, and answers each request with its body."
  @behaviour Wardrik.Channel

  @impl Wardrik.Channel
  def child_spec(opts),
    do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> started(opts) end]}}

  @impl Wardrik.Channel
  def request(opts, %{path: path, body: body, headers: headers}) do
    %{
      status: 200,
      headers: %{"content-type" => "text/plain", "x-channel" => opts[:channel]},
      body: "#{path}: #{body} (#{headers["x-signature"]})"
    }
  end

  defp started(opts) do
    send(opts[:test], {:started, opts[:wardrik], opts[:channel]})
  end
end

defmodule Wardrik.ChannelsTest do
  use ExUnit.Case, async: true

  import Wardrik.Test.Wardrik

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"
    channels = [slack: {Wardrik.Test.Echo, test: self()}]

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, Wardrik.new(name: name, store: store, channels: channels)})

    %{name: name, scope: Wardrik.as(name, "anonymous")}
  end

  test "runs each channel it's given", %{name: name} do
    assert_receive {:started, ^name, "slack"}
  end

  test "hands a chat app's request to its channel, as it came", %{scope: scope} do
    request = %{
      "channel" => "slack",
      "path" => "events",
      "body" => "{}",
      "headers" => %{"X-Signature" => "v0=abc"}
    }

    assert run!(scope, "channel.deliver", request) == %{
             "status" => 200,
             "headers" => %{"content-type" => "text/plain", "x-channel" => "slack"},
             "body" => "events: {} (v0=abc)"
           }

    assert refused(scope, "channel.deliver", %{request | "channel" => "teams"}) == :not_found
  end

  test "takes a definition that names it", %{name: name} do
    scope = Wardrik.as(name, "acme/@maria", roles: [:owner], resources: ["*"])
    definition = [model: "anthropic:claude-haiku-4-5", channels: ["slack"]]

    assert {:ok, %Wardrik.Agent{id: "acme/triage"}} =
             Wardrik.Agent.define(scope, "acme/triage", definition)
  end

  test "records what a package changes in the audit", %{name: name} do
    scope = Wardrik.as(name, "slack:T1/U2", roles: [:owner], resources: ["*"])

    data = %{
      "channel" => "slack",
      "room" => "C1",
      "agent" => %{"id" => "acme/triage"},
      "answers" => "mentions"
    }

    assert Wardrik.Audit.record(scope, "room.bound", "channels/slack/C1", data) == :ok

    assert {:ok,
            %Wardrik.Page{events: [%Wardrik.Event{type: "wardrik.room.bound", data: recorded}]}} =
             Wardrik.Audit.list(scope)

    assert recorded["actor"] == %{"id" => "slack:T1/U2"}
  end

  test "answers in Elixir", %{scope: scope} do
    assert {:ok, %Wardrik.ChannelResponse{status: 200, body: "actions: hi ()"}} =
             Wardrik.Channel.deliver(scope, "slack", "actions", body: "hi", headers: %{})
  end
end
