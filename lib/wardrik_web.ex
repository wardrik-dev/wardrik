defmodule WardrikWeb do
  @moduledoc """
  A dashboard for Wardrik's operators: agents, their timelines, approvals, audit, nodes, and every
  operation of `WardrikProtocol`.

  Mount it in a Phoenix router with `WardrikWeb.Router.wardrik_dashboard/2`. It runs each
  operation in the `Wardrik.Scope` a `WardrikWeb.Resolver` gives, so Wardrik's authorizer
  decides what each person sees and does.
  """

  @doc "Returns the dashboard path for `segments` under the dashboard's prefix, each segment encoded."
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
