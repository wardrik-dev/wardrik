defmodule Wardrik.UUID do
  @moduledoc """
  UUIDv7 (RFC 9562): 48 bits of Unix time in milliseconds, then random bits,
  so ids sort by when they were made.

      Wardrik.UUID.v7()
      #=> "0199d1f2-7c3a-7b41-9e2f-5d0c8a1b2c3d"
  """

  @doc "A new UUIDv7, as a lowercase hyphenated string."
  @spec v7() :: String.t()
  def v7 do
    millis = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)

    <<millis::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> hyphenate()
  end

  @doc "The Unix time in milliseconds a UUIDv7 was made at."
  @spec millis(String.t()) :: non_neg_integer()
  def millis(uuid) when is_binary(uuid) do
    <<high::binary-size(8), "-", low::binary-size(4), _rest::binary>> = uuid
    {:ok, <<millis::48>>} = Base.decode16(high <> low, case: :mixed)
    millis
  end

  defp hyphenate(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>),
    do: Enum.join([a, b, c, d, e], "-")
end
