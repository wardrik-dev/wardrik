defmodule WardrikDaemon.CLI.OccupantTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.CLI.Occupant

  @ps """
      1 /sbin/init
    412 /home/jon/Work/wardrik_daemon/_build/dev/rel/wardrikd/erts-16.1.2/bin/beam.smp -- -root /home/jon/Work/wardrik_daemon/_build/dev/rel/wardrikd -bindir x -sname wardrik-two@localhost
    977 /home/jon/.local/lib/wardrik/0.1.0-rc.5/erts-16.1.2/bin/beam.smp -- -root /home/jon/.local/lib/wardrik/0.1.0-rc.5 -bindir x -sname wardrik@localhost -config y
   1001 grep -sname wardrik@localhost
  """

  test "finds the node by its name, and where its release is" do
    assert Occupant.running(@ps, "wardrik@localhost") ==
             {"977", "/home/jon/.local/lib/wardrik/0.1.0-rc.5"}

    assert Occupant.running(@ps, "wardrik-two@localhost") ==
             {"412", "/home/jon/Work/wardrik_daemon/_build/dev/rel/wardrikd"}

    assert Occupant.running(@ps, "nobody@localhost") == nil
  end

  test "reads an environment as /proc holds it" do
    assert Occupant.parsed("HOME=/home/jon\0PATH=/bin\0EMPTY=\0A=b=c\0") ==
             %{"HOME" => "/home/jon", "PATH" => "/bin", "EMPTY" => "", "A" => "b=c"}
  end

  describe "told/4" do
    @occupant %Occupant{
      pid: "977",
      root: "/opt/wardrik/0.1.0-rc.5",
      env: %{"HOME" => "/home/ops"}
    }

    test "says how to reach it with the variables it was started with" do
      told = Occupant.told(@occupant, %{"HOME" => "/home/jon"}, "wardrik", false)

      assert told == """
             Another Wardrik service is running here, from /opt/wardrik/0.1.0-rc.5 (pid 977).
               Use it:      HOME=/home/ops wardrik status
               Replace it:  kill 977, then wardrik init again\
             """
    end

    test "quotes what the shell would split" do
      occupant = %{@occupant | env: %{"WARDRIK_CONFIG_DIR" => "/tmp/my wardrik's"}}

      assert Occupant.told(occupant, %{}, "wardrik", false) =~
               ~S(Use it:      WARDRIK_CONFIG_DIR='/tmp/my wardrik'\''s' wardrik status)
    end

    test "stops the one this CLI reaches with stop, and a service with systemctl" do
      assert Occupant.told(@occupant, %{}, "rik", true) =~
               "Use it:      rik status. It read what init wrote.\n  Replace it:  rik stop, then rik init again"

      assert Occupant.told(%{@occupant | service?: true}, %{}, "wardrik", false) =~
               "Replace it:  systemctl --user stop wardrik, then wardrik init again"
    end

    test "says so when its environment can't be read" do
      assert Occupant.told(%{@occupant | env: %{}}, %{}, "wardrik", false) =~
               "Use it:      wardrik status, with the environment it was started with"
    end
  end
end
