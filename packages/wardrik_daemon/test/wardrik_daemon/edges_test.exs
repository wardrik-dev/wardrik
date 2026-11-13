defmodule WardrikDaemon.EdgesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import WardrikDaemon.Test

  alias WardrikDaemon.CLI
  alias WardrikDaemon.Dirs

  test "keeps things where the XDG directories say, or under home" do
    assert %Dirs{
             config: "/home/me/.config/wardrik",
             data: "/home/me/.local/share/wardrik/store",
             data_home: "/home/me/.local/share/wardrik",
             state: "/home/me/.local/state/wardrik",
             env_file: "/home/me/.config/wardrik/env"
           } = Dirs.new(%{"HOME" => "/home/me"})

    assert %Dirs{
             config: "/xdg/config/wardrik",
             data_home: "/xdg/data/wardrik",
             state: "/xdg/state/wardrik"
           } =
             Dirs.new(%{
               "HOME" => "/home/me",
               "XDG_CONFIG_HOME" => "/xdg/config",
               "XDG_DATA_HOME" => "/xdg/data",
               "XDG_STATE_HOME" => "/xdg/state"
             })

    assert %Dirs{data: "/store", env_file: "/env"} =
             Dirs.new(%{
               "HOME" => "/h",
               "WARDRIK_DATA_DIR" => "/store",
               "WARDRIK_ENV_FILE" => "/env"
             })
  end

  test "runs the command from source" do
    assert capture_io(fn -> Mix.Tasks.Wardrik.run(["help"]) end) =~ "Usage: wardrik COMMAND"

    capture_io(:stderr, fn ->
      assert catch_exit(Mix.Tasks.Wardrik.run(["nope"])) == {:shutdown, 1}
    end)
  end

  describe "a daemon that doesn't answer" do
    setup context do
      context = dirs(context)
      path = Path.join(context.env["WARDRIK_DATA_HOME"], "cli_token")

      path
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(
        path,
        JSON.encode!(%{id: "x", secret: "s", url: "http://127.0.0.1:#{free_port()}"})
      )

      context
    end

    test "says nothing answers where it should", context do
      for argv <- [["ls"], ["ask", "triage", "hi"]] do
        stderr = capture_io(:stderr, fn -> assert CLI.main(argv, env: context.env) == 1 end)
        assert stderr =~ "Nothing answers at http://127.0.0.1:"
      end
    end
  end

  describe "a daemon that answers" do
    setup context do
      context = dirs(context)

      write(
        context,
        "config.yaml",
        "org: acme\nhttp: {port: #{free_port()}}\ndefaults: {model: #{model()}}\n"
      )

      start_daemon(context)
    end

    test "says there's no agent to ask", context do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.main(["ask", "nobody", "hi"], env: context.env) == 1
        end)

      assert stderr =~ "There's no agent nobody in acme."
    end
  end
end
