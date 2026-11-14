defmodule WardrikCore.Stored.TermTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Stored.Term

  defp kept(value) do
    value
    |> Term.dump()
    |> JSON.encode!()
    |> JSON.decode!()
    |> Term.load()
  end

  test "keeps JSON as it is, and tags what JSON can't hold" do
    values = [
      nil,
      true,
      1.5,
      "text",
      [1, "two"],
      :anthropic,
      <<0, 255>>,
      {:secret, "KEY"},
      ~U[2026-11-13 12:00:00.123456Z],
      %{"plain" => %{"nested" => [1]}},
      %{"$looks_tagged" => 1},
      %{provider: :anthropic, data: <<1, 2>>},
      %{:mixed => 1, "keys" => 2}
    ]

    for value <- values, do: assert(kept(value) == {:ok, value})
    assert Term.dump(%{"plain" => 1}) == %{"plain" => 1}
  end

  test "won't keep a struct, which needs a format of its own" do
    uri = URI.parse("https://x.test")
    assert_raise ArgumentError, fn -> Term.dump(uri) end
  end

  test "won't make an atom this release doesn't have" do
    assert {:error, reason} =
             Term.load(%{"$atom" => "wardrik_never_made_#{System.unique_integer()}"})

    assert reason =~ "this release doesn't have"
  end
end
