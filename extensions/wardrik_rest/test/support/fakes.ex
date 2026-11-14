defmodule WardrikRest.Test.Credentials do
  @moduledoc "Hands out the tokens an `Agent` holds, one per refusal, and parks when there are none."
  @behaviour Wardrik.Credentials

  @impl true
  def resolve(_request, tokens) do
    case Agent.get(tokens, & &1) do
      [] -> {:authorize, "https://accounts.test/sign-in"}
      [token | _rest] -> {:ok, token}
    end
  end

  @impl true
  def refused(%{name: name}, tokens) do
    Agent.update(tokens, fn [_refused | rest] -> rest end)
    send(self(), {:refused, name})
    :ok
  end
end

defmodule WardrikRest.Test.Keys do
  @moduledoc "Hands out the keys in its options."
  @behaviour Wardrik.Keys

  @impl true
  def fetch(%{name: name}, keys) do
    case Map.fetch(keys, name) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :not_found}
    end
  end
end
