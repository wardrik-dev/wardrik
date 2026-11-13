defmodule Wardrik.Store.Format.Term do
  # Any Erlang term, in Base64 within the JSON. For kinds without a format of their own yet.
  @moduledoc false

  @behaviour Wardrik.Store.Format

  @impl Wardrik.Store.Format
  def version, do: 1

  @impl Wardrik.Store.Format
  def dump(term) do
    term
    |> :erlang.term_to_binary()
    |> Base.encode64()
  end

  @impl Wardrik.Store.Format
  def load(1, encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
    |> then(&{:ok, &1})
  end
end
