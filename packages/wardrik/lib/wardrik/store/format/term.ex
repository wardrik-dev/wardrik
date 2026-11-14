defmodule Wardrik.Store.Format.Term do
  # Any Erlang term, in Base64 within the JSON. For kinds without a format of their own yet.
  @moduledoc false

  @behaviour WardrikCore.Format

  @impl WardrikCore.Format
  def version, do: 1

  @impl WardrikCore.Format
  def dump(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  @impl WardrikCore.Format
  def load(1, encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
    |> then(&{:ok, &1})
  end
end
