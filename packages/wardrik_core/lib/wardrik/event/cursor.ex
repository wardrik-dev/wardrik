defmodule Wardrik.Event.Cursor do
  @moduledoc """
  Where a reader of agents' logs has got to: the last sequence it has taken
  of each, as one opaque string, which `Wardrik.events/2` reads on from and
  `Wardrik.cursor/2` moves past an entry.

      Wardrik.Event.Cursor.encode(%{~A"acme/triage" => 41})  #=> "eyJhY21lL3RyaWFnZSI6NDF9"

  A log it does not name is read from its start, so `""`, naming none,
  reads every event. It is URL-safe base64 of JSON, about 50 bytes for each
  log it names, so a header the size of `Last-Event-ID` holds the place of
  150 to 200 agents.
  """

  alias Wardrik.AgentID

  @typedoc "The last sequence taken of each agent's log."
  @type positions() :: %{AgentID.t() => non_neg_integer()}

  @doc "The cursor at `positions`."
  @spec encode(positions()) :: String.t()
  def encode(positions) when map_size(positions) == 0, do: ""

  def encode(positions) do
    positions
    |> Map.new(fn {id, sequence} -> {to_string(id), sequence} end)
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc "The positions `cursor` holds, or `:error` where it is not one `encode/1` wrote."
  @spec decode(String.t()) :: {:ok, positions()} | :error
  def decode(""), do: {:ok, %{}}

  def decode(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{} = named} <- JSON.decode(json),
         positions =
           for(
             {text, at} <- named,
             position?(at),
             {:ok, id} <- [AgentID.parse(text)],
             into: %{},
             do: {id, at}
           ),
         true <- map_size(positions) == map_size(named) do
      {:ok, positions}
    else
      _other -> :error
    end
  end

  defp position?(at), do: is_integer(at) and at >= 0
end
