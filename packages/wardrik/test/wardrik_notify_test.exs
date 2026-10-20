defmodule WardrikNotifyTest do
  use ExUnit.Case, async: true

  @targets [
    audit: {WardrikNotify.Webhook, url: "https://hooks.test/wardrik"},
    globex: {WardrikNotify.Webhook, url: "https://hooks.test/globex", orgs: ["globex"]}
  ]

  test "finds a target by its name, or its name's string" do
    assert {:ok, {WardrikNotify.Webhook, _opts}} = WardrikNotify.target(@targets, :audit)
    assert {:ok, {WardrikNotify.Webhook, _opts}} = WardrikNotify.target(@targets, "globex")
    assert WardrikNotify.target(@targets, :missing) == :error
    assert WardrikNotify.target(@targets, "missing") == :error
  end

  test "attaches a supervisor delivering to its targets and the host's rooms" do
    host = Wardrik.Host.new([])

    assert [{WardrikNotify.Supervisor, [targets: []]}] = WardrikNotify.attach(host).children

    assert [{WardrikNotify.Supervisor, opts}] =
             WardrikNotify.attach(host, targets: @targets, backoff: 0).children

    assert opts == [targets: @targets, backoff: 0]
    assert_raise ArgumentError, fn -> WardrikNotify.attach(host, room: "#ops") end
  end

  test "reads config.yaml's notify, each target a webhook or a room of a channel" do
    assert {:ok, targets: []} = WardrikNotify.config(nil)

    assert {:ok, targets: targets} =
             WardrikNotify.config(%{
               "ops" => %{"channel" => "chat", "room" => "#ops", "approvers" => ["@maria"]},
               "audit" => %{"webhook" => %{"url" => "https://hooks.test/a", "secret" => "s"}},
               "log" => %{"webhook" => %{"url" => "https://hooks.test/b"}}
             })

    assert Enum.sort(targets) == [
             audit: {WardrikNotify.Webhook, url: "https://hooks.test/a", secret: "s"},
             log: {WardrikNotify.Webhook, url: "https://hooks.test/b"},
             ops: {WardrikChannel.Notices, channel: "chat", room: "#ops", approvers: ["@maria"]}
           ]
  end

  test "says where a target does not read" do
    for {section, path, message} <- [
          {[], [], "is a set of keys"},
          {%{"ops" => %{"email" => %{}}}, ["ops"], "is a webhook, or a channel and a room in it"},
          {%{"slack:#ops" => %{"webhook" => %{"url" => "x"}}}, ["slack:#ops"],
           "is not a target's name: one holds no :, which writes a room"},
          {%{"ops" => %{"channel" => "chat"}}, ["ops", "room"], "is required"},
          {%{"ops" => %{"channel" => "chat", "room" => "#ops", "colour" => "red"}},
           ["ops", "colour"], "is not a setting; expected one of channel, room, approvers"},
          {%{"ops" => %{"channel" => "chat", "room" => "x", "approvers" => "maria"}},
           ["ops", "approvers"], "is a list of who may answer, as the channel names them"},
          {%{"ops" => %{"webhook" => "x"}}, ["ops", "webhook"], "is a set of keys"},
          {%{"ops" => %{"webhook" => %{}}}, ["ops", "webhook", "url"], "is required"},
          {%{"ops" => %{"webhook" => %{"url" => "x", "colour" => "red"}}},
           ["ops", "webhook", "colour"], "is not a setting; expected one of url, secret"}
        ] do
      assert WardrikNotify.config(section) == {:error, path, message}
    end
  end

  test "a target tells the agents of its orgs, every org's unless it says" do
    assert WardrikNotify.tells?(@targets, :audit, "acme")
    assert WardrikNotify.tells?(@targets, "globex", "globex")
    refute WardrikNotify.tells?(@targets, :globex, "acme")
    refute WardrikNotify.tells?(@targets, :missing, "acme")
  end
end
