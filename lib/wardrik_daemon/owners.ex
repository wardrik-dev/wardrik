defmodule WardrikDaemon.Owners do
  @moduledoc """
  Reads who owns each agent from its ID, as the daemon names them.

  | ID | Owner |
  | --- | --- |
  | `acme/triage` | the org `acme` |
  | `acme/@jon/notes` | Jon, in `acme`, as `acme/@jon` |
  | `acme/triage/C1-1696.1234` | `acme`: a conversation runs on its agent's definition |

  Wardrik passes IDs through unread; only the daemon reads them, here.
  """

  @deployment "deployment"

  @doc """
  Returns the owner of the agent or conversation `id`, or `:error` if the daemon doesn't name it.

      WardrikDaemon.Owners.owner("acme/@jon/notes")
      #=> {:ok, "acme/@jon"}
  """
  @spec owner(String.t()) :: {:ok, String.t()} | :error
  def owner(id) do
    case String.split(id, "/") do
      [org, "@" <> person, name | conversation] ->
        owned(org <> "/@" <> person, [org, person, name], conversation)

      [org, name | conversation] ->
        owned(org, [org, name], conversation)

      _other ->
        :error
    end
  end

  defp owned(owner, segments, []), do: named(owner, segments)
  defp owned(owner, segments, [conversation]), do: named(owner, segments ++ [conversation])
  defp owned(_owner, _segments, _deeper), do: :error

  defp named(owner, segments),
    do: if(Enum.all?(segments, &segment?/1), do: {:ok, owner}, else: :error)

  @doc """
  Returns whether `owner` is one the daemon names: the deployment, an org, or a person in one.

      WardrikDaemon.Owners.valid?("acme/@jon")
      #=> true

      WardrikDaemon.Owners.valid?("acme/triage")
      #=> false
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(@deployment), do: true

  def valid?(owner) do
    case String.split(owner, "/") do
      [org] -> segment?(org)
      [org, "@" <> person] -> segment?(org) and segment?(person)
      _other -> false
    end
  end

  @doc """
  Returns `owner`'s org.

      WardrikDaemon.Owners.org("acme/@jon")
      #=> "acme"
  """
  @spec org(String.t()) :: String.t()
  def org(owner), do: owner |> String.split("/", parts: 2) |> hd()

  @doc """
  Returns the org a resource is in, or `nil` if it's in none: the deployment, and what the
  deployment owns. An owner's secrets are in its org, as are an org's ceilings.

      WardrikDaemon.Owners.org_of({:agent, "acme/@jon/notes"})
      #=> "acme"
  """
  @spec org_of(Wardrik.Authorizer.Request.resource()) :: String.t() | nil
  def org_of({:agent, id}) do
    case owner(id) do
      {:ok, owner} -> org(owner)
      :error -> nil
    end
  end

  def org_of({kind, @deployment}) when kind in [:owner, :secret, :ceiling], do: nil
  def org_of({kind, owner}) when kind in [:owner, :secret, :ceiling], do: org(owner)
  def org_of({:deployment, _name}), do: nil

  @doc """
  Returns whether `owner` is `within` itself, or a person in the org `within`.

      WardrikDaemon.Owners.within?("acme/@jon", "acme")
      #=> true

      WardrikDaemon.Owners.within?("acme", "acme/@jon")
      #=> false
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(owner, within), do: owner == within or org(owner) == within

  @doc """
  Returns the owners whose settings `owner`'s agents use, nearest first: its own, its org's for a
  person, then the deployment's.

      WardrikDaemon.Owners.chain("acme/@jon")
      #=> ["acme/@jon", "acme", "deployment"]
  """
  @spec chain(String.t()) :: [String.t()]
  def chain(owner) do
    case org(owner) do
      ^owner -> [owner, @deployment]
      org -> [owner, org, @deployment]
    end
  end

  defp segment?(segment),
    do: segment != "" and not String.contains?(segment, ["@", ":", "*", "?"]) and segment != ".."
end
