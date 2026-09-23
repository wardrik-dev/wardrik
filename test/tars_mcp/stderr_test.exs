defmodule TarsMCP.StderrTest do
  use ExUnit.Case, async: false

  import TarsMCP.Case, only: [stub_options: 1, await_tools: 1, fresh_ref: 0]

  alias TarsMCP.Server

  defp start(ref, opts) do
    start_supervised!({TarsMCP.Supervisor, servers: [{ref, stub_options(opts)}]})
    await_tools(ref)
  end

  test "a server's own output can be sent to a file instead of the terminal" do
    path = Path.join(System.tmp_dir!(), "tars-mcp-#{System.unique_integer([:positive])}.log")
    on_exit(fn -> File.rm(path) end)

    ref = fresh_ref()
    start(ref, stderr: {:file, path})

    assert {:ok, %{"ok" => true}} = TarsMCP.call(ref, "noise", %{"line" => "npm notice hello"})

    # The server writes the line before it answers, and Erlang's standard error
    # is unbuffered, so the file has it by the time the answer arrives.
    assert File.read!(path) =~ "npm notice hello"
  end

  test "a server whose output is discarded still answers" do
    ref = fresh_ref()
    start(ref, stderr: :discard)

    assert {:ok, %{"result" => %{"content" => "noise made"}}} =
             TarsMCP.call(ref, "noise", %{"line" => "gone"})
  end

  describe "the transport it builds" do
    defp server(opts) do
      Server.new(
        :stub,
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
