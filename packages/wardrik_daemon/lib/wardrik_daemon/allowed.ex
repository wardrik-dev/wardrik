defmodule WardrikDaemon.Allowed do
  @moduledoc """
  Permission checks for the daemon's HTTP routes and dashboard pages.

      :ok = WardrikDaemon.Allowed.owned(daemon, scope, "acme", {"secret.read", :secret})

  `WardrikDaemon.Authorizer` defines what each scope can do.
  """

  alias Wardrik.Error
  alias WardrikDaemon.Owners

  @doc """
  Checks that the daemon runs `owner`. Then checks that `scope` can do `action` on the owner's
  resources of type `kind`.
  """
  @spec owned(map(), Wardrik.Scope.t(), String.t(), {String.t(), atom()}) ::
          :ok | {:error, Error.t()}
  def owned(daemon, scope, owner, {action, kind}) do
    with :ok <- named(owner),
         :ok <- authorized(scope, action, {kind, owner}),
         do: kept(owner, daemon.orgs)
  end

  @doc "Checks that `scope` can do `action` on `resource`."
  @spec authorized(Wardrik.Scope.t(), String.t(), {atom(), String.t()}) ::
          :ok | {:error, Error.t()}
  def authorized(scope, action, resource) do
    case Wardrik.Authorizer.authorize(scope, action: action, resource: resource) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no #{described(resource)}.")}

      {:error, :forbidden} ->
        {:error, Error.new(:forbidden, "You may not do this to the #{described(resource)}.")}
    end
  end

  @doc "Checks that `owner` is an org, a user (`org/@name`) or `deployment`."
  @spec named(String.t()) :: :ok | {:error, Error.t()}
  def named(owner) do
    if Owners.valid?(owner),
      do: :ok,
      else:
        {:error,
         Error.new(
           :invalid_request,
           "#{owner} isn't an owner: give an org, an org/@person or deployment."
         )}
  end

  @doc "Checks that the daemon runs `owner`'s org."
  @spec kept(String.t(), map()) :: :ok | {:error, Error.t()}
  def kept("deployment", _orgs), do: :ok

  def kept(owner, orgs) do
    owner
    |> Owners.org()
    |> WardrikDaemon.Orgs.known(orgs)
  end

  defp described({:agents, owner}), do: "agents of #{owner}"
  defp described({:secret, owner}), do: "secrets of #{owner}"
  defp described({:ceiling, owner}), do: "ceilings of #{owner}"
  defp described({:mcp_server, owner}), do: "MCP servers of #{owner}"
  defp described({:notify_target, owner}), do: "notify targets of #{owner}"
  defp described({:provider, owner}), do: "OAuth apps of #{owner}"
  defp described({:connection, id}), do: "connections of #{id}"
  defp described({:token, _id}), do: "token"
end
