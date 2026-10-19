defmodule WardrikOAuth.ConfigTest do
  use ExUnit.Case, async: true

  alias WardrikOAuth.Callback

  defp read(yaml) do
    {:ok, %{"oauth" => section}} = YamlElixir.read_from_string("oauth:\n" <> yaml)
    WardrikOAuth.config(section)
  end

  defp refused(yaml) do
    {:error, path, message} = read(yaml)
    Enum.join(path, ".") <> " " <> message
  end

  test "attaches the pages a browser comes back to, and the flows' supervisor" do
    oauth = WardrikOAuth.new(redirect: [url: "https://agents.example.com/oauth"])
    host = WardrikOAuth.attach(Wardrik.Host.new(), oauth: oauth)

    assert Wardrik.Host.routes(host) == Callback.pages(oauth)
    assert Wardrik.Host.children(host) == [{WardrikOAuth.Supervisor, []}]
    assert_raise ArgumentError, fn -> WardrikOAuth.attach(Wardrik.Host.new(), redirect: []) end
  end

  test "reads the client, the redirect and the providers in their shape" do
    assert WardrikOAuth.config(nil) == {:ok, []}
    assert WardrikOAuth.config("x") == {:error, [], "is a set of keys"}

    assert {:ok, oauth} =
             read("""
               client:
                 name: Acme agents
               redirect:
                 url: https://agents.example.com/oauth/
                 open: false
               providers:
                 github:
                   resource: https://api.githubcopilot.com/mcp/
                   client_id: abc
                   scopes: [repo]
                   flow: device
             """)

    assert oauth[:client] == [name: "Acme agents"]
    assert Enum.sort(oauth[:redirect]) == [open: false, url: "https://agents.example.com/oauth"]
    assert oauth[:providers][:github][:scopes] == ["repo"]
    assert oauth[:providers][:github][:flow] == :device

    assert {:ok, redirect: [url: "http://localhost:4747/oauth"]} =
             read("  redirect:\n    url: http://localhost:4747/oauth\n")

    assert {:ok, providers: []} = read("  providers:\n")
  end

  test "a redirect is one a browser may come back to" do
    for {yaml, said} <- [
          {"url: http://agents.example.com", "url is an https:// URL, or http:// on loopback"},
          {"url: https://agents.example.com/?a=1", "url is an https:// URL"},
          {"url: https://agents.example.com/#top", "url is an https:// URL"},
          {"url: ftp://agents.example.com", "url is an https:// URL"},
          {"url: 4599", "url is an https:// URL"},
          {"port: 4600", "port is not"},
          {"open: sometimes", "open is true or false"},
          {"uri: https://agents.example.com", "uri is not"}
        ] do
      assert refused("  redirect:\n    #{yaml}\n") =~ "redirect." <> said
    end

    assert refused("  redirect: [x]\n") == "redirect is a set of keys"
    assert refused("  issuer: x\n") =~ "issuer is not a setting"
    assert Callback.redirect?("https://agents.example.com/oauth")
    refute Callback.redirect?("https://user@agents.example.com/oauth")
  end

  test "a provider says how its users authorize, and what it sends" do
    assert refused("  providers:\n    github:\n      resource: https://x\n      flow: phone\n") =~
             "providers.github.flow is auto, browser or device"

    assert refused("  providers:\n    github:\n      redirect_uri: https://y\n") =~
             "providers.github.redirect_uri is not a setting"

    assert {:ok, oauth} =
             read(
               "  providers:\n    google:\n      resource: https://x\n" <>
                 "      authorization_params:\n        access_type: offline\n" <>
                 "        prompt: consent\n        max_age: 0\n"
             )

    assert oauth[:providers][:google][:authorization_params] ==
             %{"access_type" => "offline", "prompt" => "consent", "max_age" => "0"}

    params = "  providers:\n    google:\n      authorization_params:\n"

    assert refused(params <> "        redirect_uri: https://y\n") =~
             "authorization_params.redirect_uri is one Wardrik sets itself"

    assert refused(params <> "        nested: {a: b}\n") =~
             "authorization_params.nested is a string, a number or true or false"

    assert refused("  providers:\n    google:\n      authorization_params: offline\n") =~
             "providers.google.authorization_params is a table"
  end

  test "a provider's client secret goes only to an issuer it names" do
    assert refused(
             "  providers:\n    github:\n      resource: https://x\n" <>
               "      client_id: a\n      client_secret: s\n"
           ) =~ "providers.github.client_secret is sent only to an issuer the provider names"

    assert {:ok, oauth} =
             read(
               "  providers:\n    github:\n      resource: https://x\n" <>
                 "      issuer: https://y\n      client_id: a\n      client_secret: s\n"
             )

    assert oauth[:providers][:github][:client_secret] == "s"
  end
end
