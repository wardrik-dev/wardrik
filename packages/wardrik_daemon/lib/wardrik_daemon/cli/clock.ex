defmodule WardrikDaemon.CLI.Clock do
  @moduledoc false

  @doc """
  Returns how long from `now` until `at`, an ISO 8601 time, or `nil` for `nil`.

      WardrikDaemon.CLI.Clock.from_now("2026-10-27T16:00:00Z", ~U[2026-10-27 12:50:00Z])
      #=> "in 3h 10m"
  """
  @spec from_now(String.t() | nil, DateTime.t()) :: String.t() | nil
  def from_now(at, now \\ DateTime.utc_now())
  def from_now(nil, _now), do: nil

  def from_now(at, now) do
    {:ok, at, _offset} = DateTime.from_iso8601(at)
    at |> DateTime.diff(now, :minute) |> max(0) |> waited()
  end

  defp waited(minutes) when minutes < 1, do: "now"
  defp waited(minutes) when minutes < 60, do: "in #{minutes}m"
  defp waited(minutes) when minutes < 1_440, do: hours(div(minutes, 60), rem(minutes, 60))
  defp waited(minutes), do: "in #{div(minutes, 1_440)}d #{div(rem(minutes, 1_440), 60)}h"

  defp hours(hours, 0), do: "in #{hours}h"
  defp hours(hours, minutes), do: "in #{hours}h #{minutes}m"

  @doc "Returns `count` in few characters, as `950`, `12.3k` or `1.2M`."
  @spec amount(non_neg_integer()) :: String.t()
  def amount(count) when count < 1_000, do: Integer.to_string(count)
  def amount(count) when count < 1_000_000, do: shortened(count / 1_000, "k")
  def amount(count), do: shortened(count / 1_000_000, "M")

  defp shortened(value, unit), do: :erlang.float_to_binary(value, decimals: 1) <> unit
end
