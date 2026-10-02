defmodule WardrikConsole.AnsiTest do
  use ExUnit.Case, async: true

  alias WardrikConsole.Ansi

  defp text(data, colour?), do: data |> Ansi.chardata(colour?) |> IO.iodata_to_binary()

  test "plain text keeps the words and drops the styles" do
    data = ["a ", Owl.Data.tag(["b ", Owl.Data.tag("c", :red)], :bright)]

    assert text(data, false) == "a b c"
  end

  test "in colour, a tag that closes opens again the styles around it" do
    data = ["a ", Owl.Data.tag(["b ", Owl.Data.tag("c", :red), " d"], :bright), " e"]

    assert text(data, true) == "a \e[1mb \e[31mc\e[0m\e[1m d\e[0m e\e[0m"
  end

  test "a hyperlink is opened and closed on its own, and plain text keeps only its words" do
    data = Owl.Data.tag("docs", [{:hyperlink, "https://example.com"}, :underline])

    assert text(data, true) == "\e]8;;https://example.com\e\\\e[4mdocs\e]8;;\e\\\e[0m\e[0m"
    assert text(data, false) == "docs"
  end
end
