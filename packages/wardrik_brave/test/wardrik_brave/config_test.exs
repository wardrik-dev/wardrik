defmodule WardrikBrave.ConfigTest do
  use ExUnit.Case, async: true

  alias WardrikBrave.Config

  test "reaches Brave itself, with no key, unless told otherwise" do
    config = Config.new()

    assert config.api_key == nil
    assert config.base_url == "https://api.search.brave.com"
    assert config.req_options == []
  end

  test "options override the defaults" do
    config = Config.new(api_key: "other", base_url: "https://elsewhere.test")

    assert config.api_key == "other"
    assert config.base_url == "https://elsewhere.test"
  end

  test "a config with a key is usable" do
    assert Config.usable?(Config.new(api_key: "key"))
  end

  test "a config with no key is not usable, rather than a boot failure" do
    refute Config.usable?(Config.new())
    refute Config.usable?(Config.new(api_key: ""))
  end
end
