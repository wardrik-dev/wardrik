defmodule Wardrik.Resource do
  @moduledoc """
  A resource names what an action acts on, as IAM names one: `acme/agent/triage` is the agent
  `acme/triage`, `acme/@jon/agent/triage` is `acme/@jon/triage`, `acme/mcp_server/linear` is the org's
  MCP server `linear`, `acme/@jon/connection/github` is Jon's GitHub account, and `deployment` is
  the deployment.
  """

  alias Wardrik.AgentID

  @deployment "deployment"

  @doc """
  Returns the resource of the agent `id`, or `:error` when it isn't an agent's ID. A conversation's
  is its agent's with the conversation after it, as `acme/agent/triage/conversation/C1-1696.1234`.
  """
  @spec agent(String.t()) :: {:ok, String.t()} | :error
  def agent(id) do
    case AgentID.parse(id) do
      {:ok, %AgentID{owner: owner, name: name, conversation: nil}} ->
        {:ok, owner <> "/agent/" <> name}

      {:ok, %AgentID{owner: owner, name: name, conversation: conversation}} ->
        {:ok, owner <> "/agent/" <> name <> "/conversation/" <> conversation}

      :error ->
        :error
    end
  end

  @doc "Returns the resource of what `owner` holds: its `kind`, and the one named, if any."
  @spec owned(String.t(), String.t(), String.t() | nil) :: String.t()
  def owned(owner, kind, nil), do: owner <> "/" <> kind
  def owned(owner, kind, name), do: owner <> "/" <> kind <> "/" <> name

  @doc "Returns the deployment's resource."
  @spec deployment() :: String.t()
  def deployment, do: @deployment
end
