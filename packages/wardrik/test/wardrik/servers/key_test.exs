defmodule Wardrik.Servers.KeyTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Servers.Key

  test "a deployment's server is written by its name alone" do
    assert to_string(Key.deployment("github")) == "github"
  end

  test "an owner's server is written under its owner" do
    assert to_string(Key.new(Prefix.new!(org: "acme"), "crm")) == "acme/crm"
    assert to_string(Key.new(Prefix.new!(org: "acme", user: "jon"), "crm")) == "acme/@jon/crm"
  end
end
