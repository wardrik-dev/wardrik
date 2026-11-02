defmodule Wardrik.Test.Directory do
  @moduledoc """
  The test apps' own directory of agents. Like any app, they choose their agents' IDs, and these
  choose IDs that start with their owner's: `acme/@maria/notes` is `acme/@maria`'s, `acme/triage`
  is `acme`'s. Wardrik itself never reads them.
  """

  @doc "Returns the owner of the agent `id`, as the test apps named it."
  @spec owner(String.t()) :: String.t()
  def owner(id) do
    case String.split(id, "/") do
      [org, "@" <> _ = person | _rest] -> org <> "/" <> person
      [org | _rest] -> org
    end
  end
end
