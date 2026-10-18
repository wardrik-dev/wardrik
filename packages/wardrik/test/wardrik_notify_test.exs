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

  test "a target tells the agents of its orgs, every org's unless it says" do
    assert WardrikNotify.tells?(@targets, :audit, "acme")
    assert WardrikNotify.tells?(@targets, "globex", "globex")
    refute WardrikNotify.tells?(@targets, :globex, "acme")
    refute WardrikNotify.tells?(@targets, :missing, "acme")
  end
end
