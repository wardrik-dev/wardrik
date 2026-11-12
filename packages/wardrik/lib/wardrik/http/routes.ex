defmodule WardrikHTTP.Routes do
  @moduledoc false

  segment = fn
    "{" <> name -> {:param, String.trim_trailing(name, "}")}
    literal -> literal
  end

  pattern = fn path -> path |> String.split("/", trim: true) |> Enum.map(segment) end

  @routes WardrikProtocol.operations()
          |> Enum.flat_map(fn operation ->
            for path <- [operation.path, operation.conversation],
                path != nil,
                do: {String.upcase(operation.method), pattern.(path), operation}
          end)
          |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))

  @doc """
  Returns the operation for `method` and the decoded path `segments`, with its path parameters, or
  `:error`.

  Each parameter takes one segment. An operation on a conversation matches its conversation route
  too, which gives `"conversation"`.

      WardrikHTTP.Routes.match("POST", ["v1", "agents", "agt_1", "messages"])
      #=> {:ok, %{id: "agent.ask", ...}, %{"agent" => "agt_1"}}

      WardrikHTTP.Routes.match("GET", ~w(v1 agents agt_1 conversations C1 timeline))
      #=> {:ok, %{id: "agent.timeline", ...}, %{"agent" => "agt_1", "conversation" => "C1"}}
  """
  @spec match(String.t(), [String.t()]) ::
          {:ok, WardrikProtocol.operation(), %{String.t() => String.t()}} | :error
  def match(method, segments) do
    @routes
    |> Map.get(method, [])
    |> Enum.find_value(:error, fn {pattern, operation} ->
      matched(pattern, segments, operation)
    end)
  end

  defp matched(pattern, segments, operation) do
    case params(pattern, segments, %{}) do
      {:ok, params} -> {:ok, operation, params}
      :error -> nil
    end
  end

  defp params([], [], params), do: {:ok, params}

  defp params([{:param, name} | pattern], [value | segments], params),
    do: params(pattern, segments, Map.put(params, name, value))

  defp params([literal | pattern], [literal | segments], params),
    do: params(pattern, segments, params)

  defp params(_pattern, _segments, _params), do: :error
end
