defmodule WardrikHTTPTest do
  use ExUnit.Case, async: true

  test "attaches the workers' tools, and what serves the API on the host's store" do
    store = Wardrik.Test.store()
    host = WardrikHTTP.attach(Wardrik.Host.new(store: store), port: 0, workers: [trusted: true])

    assert Wardrik.Host.sources(host) == %{"workers" => WardrikHTTP.Workers}

    assert Wardrik.Host.children(host) == [
             {WardrikHTTP.Access, store: store},
             {WardrikHTTP.Workers, []},
             {WardrikHTTP.Listener, port: 0, workers: [trusted: true]}
           ]

    assert_raise ArgumentError, fn -> WardrikHTTP.attach(Wardrik.Host.new(), mounts: []) end
  end

  test "reads config.yaml's http, and says where it does not read" do
    assert WardrikHTTP.config(nil) == {:ok, []}

    assert WardrikHTTP.config(%{"port" => 4800, "ip" => "0.0.0.0", "trusted_workers" => true}) ==
             {:ok, [ip: {0, 0, 0, 0}, port: 4800, workers: [trusted: true]]}

    for {section, path, message} <- [
          {"x", [], "is a set of keys"},
          {%{"socket" => 1}, ["socket"],
           "is not a setting; expected one of port, ip, trusted_workers"},
          {%{"port" => 0}, ["port"], "is a port number"},
          {%{"ip" => "nowhere"}, ["ip"], "is an address, such as 127.0.0.1 or 0.0.0.0"},
          {%{"ip" => 1}, ["ip"], "is an address, such as 127.0.0.1 or 0.0.0.0"},
          {%{"trusted_workers" => "yes"}, ["trusted_workers"], "is true or false"}
        ] do
      assert WardrikHTTP.config(section) == {:error, path, message}
    end
  end
end
