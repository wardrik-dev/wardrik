defmodule WardrikDaemon.Allowed do
  @moduledoc """
  Permission checks for the daemon's HTTP routes and dashboard pages.

      :ok = WardrikDaemon.Allowed.check_owned(daemon, scope, "acme", {"secret.read", :secret})

  `WardrikDaemon.Authorizer` defines what each scope can do.
  """

  alias Wardrik.Error
  alias WardrikDaemon.Owners

  @doc """
  Checks that the daemon runs `owner`. Then checks that `scope` can do `action` on the owner's
  resources of type `kind`.
  """
  @spec check_owned(map(), Wardrik.Scope.t(), String.t(), {String.t(), atom()}) ::
          :ok | {:error, Error.t()}
  def check_owned(daemon, scope, owner, {action, kind}) do
    with :ok <- check_owner_name(owner),
         :ok <- check_authorized(scope, action, {kind, owner}),
         do: check_kept(owner, daemon.orgs)
  end

  @doc "Checks that `scope` can do `action` on `resource`."
  @spec check_authorized(Wardrik.Scope.t(), String.t(), {atom(), String.t()}) ::
          :ok | {:error, Error.t()}
  def check_authorized(scope, action, resource) do
    case Wardrik.Authorizer.authorize(scope, action: action, resource: resource) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no #{describe(resource)}.")}

      {:error, :forbidden} ->
        {:error, Error.new(:forbidden, "You may not do this to the #{describe(resource)}.")}
    end
  end

  @doc "Checks that `owner` is an org, a user (`org/@name`) or `deployment`."
  @spec check_owner_name(String.t()) :: :ok | {:error, Error.t()}
  def check_owner_name(owner) do
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
  @spec check_kept(String.t(), map()) :: :ok | {:error, Error.t()}
  def check_kept("deployment", _orgs), do: :ok

  def check_kept(owner, orgs) do
    owner
    |> Owners.org()
    |> WardrikDaemon.Orgs.check_known(orgs)
  end

  defp describe({:agents, owner}), do: "agents of #{owner}"
  defp describe({:secret, owner}), do: "secrets of #{owner}"
  defp describe({:ceiling, owner}), do: "ceilings of #{owner}"
  defp describe({:mcp_server, owner}), do: "MCP servers of #{owner}"
  defp describe({:notify_target, owner}), do: "notify targets of #{owner}"
  defp describe({:provider, owner}), do: "OAuth apps of #{owner}"
  defp describe({:connection, id}), do: "connections of #{id}"
  defp describe({:token, _id}), do: "token"
end
