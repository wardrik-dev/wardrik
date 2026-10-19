defmodule Wardrik.Event.CursorTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Event.Cursor

  @triage AgentID.parse!("acme/triage")
  @assistant AgentID.parse!("acme/@jon/assistant")

  test "reads back the positions it was made at, and names none as the empty string" do
    positions = %{@triage => 41, @assistant => 7}

    assert {:ok, ^positions} = positions |> Cursor.encode() |> Cursor.decode()
    assert Cursor.encode(%{}) == ""
    assert {:ok, %{}} = Cursor.decode("")
  end

  test "is text a URL or a header carries, about 50 bytes a log" do
    positions =
      Map.new(1..150, &{AgentID.new!("support-#{&1}", org: "acme", user: "jon"), 1_000_000 + &1})

    cursor = Cursor.encode(positions)

    assert cursor =~ ~r/\A[A-Za-z0-9_-]+\z/
    assert byte_size(cursor) / 150 < 50
  end

  test "is no cursor where it holds anything but logs and sequences" do
    for text <- [
          "not base64!",
          Base.url_encode64("[1]"),
          encoded(%{"acme" => 1}),
          encoded(%{"acme/triage" => -1}),
          encoded(%{"acme/triage" => "1"})
        ] do
      assert Cursor.decode(text) == :error
    end
  end

  defp encoded(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)
end
