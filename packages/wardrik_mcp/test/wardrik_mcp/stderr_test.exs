defmodule WardrikMCP.StderrTest do
  use ExUnit.Case, async: false

  import WardrikMCP.Test.Case, only: [stub_options: 1, await_tools: 1, fresh_key: 0, context: 0]

  alias Wardrik.Servers.Key
  alias WardrikMCP.Server

  defp start(key, opts) do
    start_supervised!(
      {WardrikMCP.Supervisor, servers: [{String.to_atom(key.name), stub_options(opts)}]}
    )

    await_tools(key)
  end

  test "a server's own output can be sent to a file instead of the terminal" do
    path = Path.join(System.tmp_dir!(), "wardrik-mcp-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)

    key = fresh_key()
    start(key, stderr: {:file, path})

    assert {:ok, %{"ok" => true}} =
             WardrikMCP.call(key, "noise", %{"line" => "npm notice hello"}, context())

    # The server writes the line before it answers, and Erlang's standard error
    # is unbuffered, so the file has it by the time the answer arrives.
    assert File.read!(path) =~ "npm notice hello"
  end

  test "a server whose output is discarded still answers" do
    key = fresh_key()
    start(key, stderr: :discard)

    assert {:ok, %{"result" => %{"content" => "noise made"}}} =
             WardrikMCP.call(key, "noise", %{"line" => "gone"}, context())
  end

  describe "the transport it builds" do
    defp server(opts) do
      Server.new(
        Key.deployment("stub"),
        Keyword.merge(
          [transport: {:stdio, command: "npx", args: ["-y", "x"]}, inherit_env: :all],
          opts
        )
      )
    end

    test "is left alone where output is inherited" do
      assert {:stdio, opts} = server(stderr: :inherit).transport
      assert opts[:command] == "npx"
    end

    test "runs the command under a shell that points stderr away" do
      assert {:stdio, opts} = server(stderr: :discard).transport

      assert Path.basename(opts[:command]) == "sh"
      assert ["-c", script] = opts[:args]
      assert script == "exec 'npx' '-y' 'x' 2>/dev/null"
    end

    test "quotes what it puts in the script" do
      transport = {:stdio, command: "my server", args: ["it's"]}

      assert {:stdio, opts} =
               server(stderr: {:file, "/tmp/a b.log"}, transport: transport).transport

      assert ["-c", script] = opts[:args]

      assert script == "exec 'my server' 'it'\\''s' 2>>'/tmp/a b.log'"
    end

    test "leaves an HTTP transport alone" do
      transport = {:streamable_http, base_url: "https://example.com"}

      assert {:streamable_http, _opts} = server(stderr: :discard, transport: transport).transport
    end
  end
end
