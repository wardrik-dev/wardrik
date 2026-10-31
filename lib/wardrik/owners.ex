defmodule Wardrik.Owners do
  @moduledoc """
  Owners hold agents, servers, secrets and settings.

  | Owner | Is |
  | --- | --- |
  | `deployment` | the deployment |
  | `acme` | the org `acme` |
  | `acme/@jon` | Jon, in `acme` |

  Settings resolve along `chain/1`, nearest first, so a person's agent finds their own server
  before their org's, and their org's before the deployment's.

  Credentials never do. An account belongs to the principal who connected it, and only their
  agents use it.
  """

  alias Wardrik.Resource

  @typedoc "An owner, as `deployment`, `acme` or `acme/@jon`."
  @type t() :: String.t()

  @doc """
  Parses `owner`. Returns `:error` for anything that isn't the deployment, an org or a person.

      Wardrik.Owners.parse("acme/@jon")
      #=> {:ok, %{org: "acme", person: "jon"}}

      Wardrik.Owners.parse("deployment")
      #=> {:ok, %{org: nil, person: nil}}
  """
  @spec parse(String.t()) ::
          {:ok, %{org: String.t() | nil, person: String.t() | nil}} | :error
  def parse(owner) do
    if owner == Resource.deployment(),
      do: {:ok, %{org: nil, person: nil}},
      else: owner |> String.split("/") |> parsed()
  end

  defp parsed([org]) do
    if segment?(org), do: {:ok, %{org: org, person: nil}}, else: :error
  end

  defp parsed([org, "@" <> person]) do
    if segment?(org) and segment?(person), do: {:ok, %{org: org, person: person}}, else: :error
  end

  defp parsed(_other), do: :error

  @doc """
  Returns the owners whose settings `owner` uses, nearest first.

      Wardrik.Owners.chain("acme/@jon")
      #=> ["acme/@jon", "acme", "deployment"]

  A principal that isn't an owner, as `slack:T0123/U024BE7LH`, gets its own and the
  deployment's.
  """
  @spec chain(String.t()) :: [t()]
  def chain(owner) do
    case parse(owner) do
      {:ok, %{org: nil}} -> [Resource.deployment()]
      {:ok, %{org: org, person: nil}} -> [org, Resource.deployment()]
      {:ok, %{org: org}} -> [owner, org, Resource.deployment()]
      :error -> [owner, Resource.deployment()]
    end
  end

  defp segment?(segment),
    do: segment != "" and not String.contains?(segment, ["/", "@", ":", "*", "?"])
end
