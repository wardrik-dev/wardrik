defmodule Wardrik.Resource do
  @moduledoc """
  A resource names what an action acts on, as IAM names one: `acme/agent/triage` is the agent
  `acme/triage`, `acme/@jon/agent/triage` is `acme/@jon/triage`, `acme/mcp_server/linear` is the org's
  MCP server `linear`, `acme/@jon/connection/github` is Jon's GitHub account, and `deployment` is
  the deployment.
  """

  @deployment "deployment"

  @doc "Returns the resource of the agent `id`, or `:error` when it isn't an agent's ID."
  @spec agent(String.t()) :: {:ok, String.t()} | :error
  def agent(id) do
    case String.split(id, "/") do
      [org, "@" <> _user = user, name] -> named([org, user], name)
      [org, name] -> named([org], name)
      _other -> :error
    end
  end

  @doc "Returns the resource of what `owner` holds: its `kind`, and the one named, if any."
  @spec owned(String.t(), String.t(), String.t() | nil) :: String.t()
  def owned(owner, kind, nil), do: owner <> "/" <> kind
  def owned(owner, kind, name), do: owner <> "/" <> kind <> "/" <> name

  @doc "Returns the deployment's resource."
  @spec deployment() :: String.t()
  def deployment, do: @deployment

  defp named(owner, name) do
    if Enum.all?([name | owner], &segment?/1),
      do: {:ok, Enum.join(owner ++ ["agent", name], "/")},
      else: :error
  end

  defp segment?(segment), do: segment != "" and not String.contains?(segment, ["*", "?"])
end
