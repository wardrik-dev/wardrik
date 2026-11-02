defmodule Wardrik.AgentID do
  @moduledoc """
  Parses agent IDs.

      Wardrik.AgentID.parse("acme/@jon/triage/C1-1696.1234")
      #=> {:ok, %Wardrik.AgentID{owner: "acme/@jon", name: "triage", conversation: "C1-1696.1234"}}

  An ID is one of:

    * `acme/triage` - an org's agent.
    * `acme/@jon/triage` - a person's agent.
    * `acme/triage/C1-1696.1234` or `acme/@jon/triage/C1-1696.1234` - a conversation. It runs on
      its agent's definition, with its own history.

  Only the owner holds a `/@` segment. No segment may be empty or contain `:`, `*` or `?`, and an
  owner's segments may not contain `@` beyond the person's leading one. `:` marks people known
  elsewhere, as `slack:T0123/U024BE7LH`. `*` and `?` are for patterns.
  """

  @enforce_keys [:owner, :name, :conversation]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{owner: String.t(), name: String.t(), conversation: String.t() | nil}

  @doc "Parses `id`. Returns `:error` if it isn't an agent or conversation ID."
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(id) do
    {owner, rest} = id |> String.split("/") |> owner()

    if owner?(owner), do: new(owner, rest), else: :error
  end

  @doc """
  Returns the ID of the agent whose definition `id` runs on.

      Wardrik.AgentID.agent("acme/triage/C1-1696.1234")
      #=> "acme/triage"

  Returns `id` unchanged if it's an agent ID or doesn't parse.
  """
  @spec agent(String.t()) :: String.t()
  def agent(id) do
    case parse(id) do
      {:ok, %__MODULE__{owner: owner, name: name}} -> owner <> "/" <> name
      :error -> id
    end
  end

  @doc "Returns `true` if `id` is a conversation ID."
  @spec conversation?(String.t()) :: boolean()
  def conversation?(id), do: match?({:ok, %__MODULE__{conversation: c}} when c != nil, parse(id))

  defp owner([org, "@" <> _person = person | rest]), do: {org <> "/" <> person, rest}
  defp owner([org | rest]), do: {org, rest}

  defp owner?(owner) do
    case String.split(owner, "/") do
      [org] -> owned?(org)
      [org, "@" <> person] -> owned?(org) and owned?(person)
    end
  end

  defp owned?(segment), do: segment?(segment) and not String.contains?(segment, ["/", "@"])

  defp new(owner, [name]), do: new(owner, [name, nil])

  defp new(owner, [name, conversation]) do
    if Enum.all?([name | List.wrap(conversation)], &segment?/1),
      do: {:ok, %__MODULE__{owner: owner, name: name, conversation: conversation}},
      else: :error
  end

  defp new(_owner, _rest), do: :error

  defp segment?(segment), do: segment != "" and not String.contains?(segment, ["*", "?", ":"])
end
