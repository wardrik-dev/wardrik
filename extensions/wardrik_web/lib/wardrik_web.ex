defmodule WardrikWeb do
  @moduledoc """
  A web dashboard for Wardrik agents.

  It shows agents and their timelines, approvals, the audit log and cluster nodes. It has a form
  for every `WardrikProtocol` operation.

  To add it to your app, see `WardrikWeb.Router.wardrik_dashboard/2`.

  The dashboard runs every action in the `Wardrik.Scope` that your `WardrikWeb.Resolver` returns.
  Wardrik's authorizer checks each action.
  """

  @doc "Returns the path to a dashboard page, with each of `segments` URL-encoded."
  @spec path(WardrikWeb.Dashboard.t(), [String.t()], map()) :: String.t()
  def path(%WardrikWeb.Dashboard{prefix: prefix}, segments, query \\ %{}) do
    path =
      Enum.map_join(segments, fn segment ->
        "/" <> URI.encode(segment, &URI.char_unreserved?/1)
      end)

    path = String.trim_trailing(prefix, "/") <> path
    path = if path == "", do: "/", else: path

    case Map.reject(query, fn {_key, value} -> value in [nil, ""] end) do
      empty when map_size(empty) == 0 -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end
end
