defmodule WardrikOAuth.BrowserTest do
  use WardrikOAuth.Test.Case, async: false

  alias WardrikOAuth.Browser

  defp desktop(env) do
    previous = Map.new(~w(DISPLAY WAYLAND_DISPLAY), &{&1, System.get_env(&1)})
    Enum.each(env, &put_env/1)
    on_exit(fn -> Enum.each(previous, &put_env/1) end)
  end

  defp put_env({name, nil}), do: System.delete_env(name)
  defp put_env({name, value}), do: System.put_env(name, value)

  describe "available?/1" do
    test "is not where no command opens links" do
      configure(redirect: [opener: "no-such-opener-anywhere"])
      refute Browser.available?(opener: oauth().redirect[:opener])
    end

    test "is where a command opens links on a desktop session" do
      configure(redirect: [opener: "sh"])
      desktop(%{"DISPLAY" => ":0", "WAYLAND_DISPLAY" => nil})

      assert Browser.available?(opener: oauth().redirect[:opener])
    end

    test "is not on a machine reached with no desktop session" do
      if :os.type() == {:unix, :darwin} do
        :ok
      else
        configure(redirect: [opener: "sh"])
        desktop(%{"DISPLAY" => nil, "WAYLAND_DISPLAY" => nil})

        refute Browser.available?(opener: oauth().redirect[:opener])
      end
    end
  end
end
