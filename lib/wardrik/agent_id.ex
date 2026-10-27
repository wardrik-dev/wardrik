defmodule Wardrik.AgentID do
  @moduledoc """
  Reads agent IDs: `acme/triage`, `acme/@jon/triage`, and a conversation of either, as
  `acme/triage/C1-1696.1234`, which runs on its agent's definition with a history of its own. No
  segment holds `:`, which names a person known elsewhere, as `slack:T0123/U024BE7LH`, nor `*` or
  `?`, which patterns take.
  """

  @enforce_keys [:owner, :name, :conversation]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{owner: String.t(), name: String.t(), conversation: String.t() | nil}

  @doc "Reads the ID `id`, or returns `:error` when it isn't an agent's or a conversation's."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(id) do
    case String.split(id, "/") do
      [org, "@" <> _user = user, name] -> new([org, user], name, nil)
      [org, "@" <> _user = user, name, conversation] -> new([org, user], name, conversation)
      [org, name] -> new([org], name, nil)
      [org, name, conversation] -> new([org], name, conversation)
      _other -> :error
    end
  end

  @doc "Returns the ID of the agent whose definition `id` runs on: itself, or a conversation's agent."
  @spec agent(String.t()) :: String.t()
  def agent(id) do
    case parse(id) do
      {:ok, %__MODULE__{owner: owner, name: name}} -> owner <> "/" <> name
      :error -> id
    end
  end

  @doc "Returns whether `id` is one of an agent's conversations."
  @spec conversation?(String.t()) :: boolean()
  def conversation?(id), do: match?({:ok, %__MODULE__{conversation: c}} when c != nil, parse(id))

  defp new(owner, name, conversation) do
    if Enum.all?(owner ++ [name | List.wrap(conversation)], &segment?/1),
      do:
        {:ok, %__MODULE__{owner: Enum.join(owner, "/"), name: name, conversation: conversation}},
      else: :error
  end

  defp segment?(segment), do: segment != "" and not String.contains?(segment, ["*", "?", ":"])
end
