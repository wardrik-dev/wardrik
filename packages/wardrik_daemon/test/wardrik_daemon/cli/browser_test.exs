defmodule WardrikDaemon.CLI.BrowserTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.CLI.Browser

  test "runs BROWSER with the link, last or where %s is, over SSH too" do
    browser = browser()
    url = "http://127.0.0.1:4747/web/sign-in?code=a&b=$(touch nope)"

    opened = opened(browser)
    assert Browser.open(%{"BROWSER" => browser.script, "SSH_TTY" => "/dev/pts/1"}, url) == :ok
    assert opened.() == url

    opened = opened(browser)
    assert Browser.open(%{"BROWSER" => "#{browser.script} --new %s:other"}, url) == :ok
    assert opened.() == "--new " <> url
  end

  test "opens nothing over SSH, or on Linux without a display" do
    url = "http://127.0.0.1:4747/web"

    assert Browser.open(%{"SSH_CONNECTION" => "10.0.0.2 50000 10.0.0.1 22"}, url) ==
             {:error, :remote}

    if :os.type() == {:unix, :linux}, do: assert(Browser.open(%{}, url) == {:error, :remote})
  end
end
