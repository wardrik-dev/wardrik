defmodule WardrikBrave.ConfigTest do
  use ExUnit.Case, async: true

  alias WardrikBrave.Config

  test "reads the key, base url and transport options from app env" do
    config = Config.new()

    assert config.api_key == "test-brave-api-key"
    assert config.base_url == "https://brave.test"
    assert Keyword.has_key?(config.req_options, :plug)
  end

  test "options override app env" do
    assert Config.new(api_key: "other", base_url: "https://elsewhere.test").api_key == "other"
  end

  test "a config with a key is usable" do
    assert Config.usable?(Config.new())
  end

  test "a config with no key is not usable, rather than a boot failure" do
    refute Config.usable?(Config.new(api_key: nil))
    refute Config.usable?(Config.new(api_key: ""))
  end
end
