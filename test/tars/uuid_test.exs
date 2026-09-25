defmodule Tars.UUIDTest do
  use ExUnit.Case, async: true

  test "a v7 is a lowercase version 7, RFC 9562 variant UUID" do
    assert Tars.UUID.v7() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "carries the millisecond it was made at, so ids sort by time" do
    before = System.system_time(:millisecond)
    uuid = Tars.UUID.v7()

    assert Tars.UUID.millis(uuid) in before..System.system_time(:millisecond)
  end

  test "no two are the same" do
    uuids = Stream.repeatedly(&Tars.UUID.v7/0) |> Enum.take(1_000)

    assert uuids |> Enum.uniq() |> length() == 1_000
  end
end
