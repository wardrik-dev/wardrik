defmodule WardrikDaemon.Doctor.MCP do
  @moduledoc false

  import WardrikDaemon.Doctor, only: [counted: 2, reachable: 2]

  @version "2025-06-18"
  @timeout 10_000

  @doc """
  Checks a server in `config.yaml`: that a command is on the PATH, or that a URL lists tools
  with its headers, and how many `only` and `except` keep. A server reached with each user's account, or with headers the vault holds,
  is only reached.
  """
  @spec check({atom() | String.t(), keyword()}, keyword()) :: WardrikDaemon.Doctor.check()
  def check({name, opts}, req_options) do
    server = Wardrik.MCP.Server.new!(name, opts)
    check("mcp #{name}", server, Keyword.fetch!(opts, :transport), req_options)
  end

  defp check(label, _server, {:stdio, transport}, _req_options) do
    command = Keyword.fetch!(transport, :command)

    if System.find_executable(command),
      do: {:ok, label, "runs #{command}"},
      else: {:fail, label, "runs #{command}, which isn't on this machine's PATH"}
  end

  defp check(label, server, {:streamable_http, transport}, req_options) do
    url = Keyword.fetch!(transport, :url)
    %URI{host: host, port: port} = URI.parse(url)
    at = "#{host}:#{port}"

    with :ok <- reachable(host, port),
         nil <- unlisted(server, transport),
         {:ok, names} <- listed(url, Keyword.get(transport, :headers, %{}), req_options) do
      {:ok, label, "lists #{counted(length(names), "tool")} at #{at}#{offered(server, names)}"}
    else
      {:error, why} -> {:fail, label, "doesn't answer at #{at}: #{why}"}
      {:refused, why} -> {:fail, label, "answers at #{at}, but #{why}"}
      why when is_binary(why) -> {:ok, label, "answers at #{at}; #{why}"}
    end
  end

  defp unlisted(server, transport) do
    headers = Keyword.get(transport, :headers, %{})

    cond do
      server.credential_name ->
        "each user's account reaches it, so its tools aren't listed here"

      Enum.any?(headers, fn {_name, value} -> sealed?(value) end) ->
        "the vault holds its headers, so its tools aren't listed here"

      true ->
        nil
    end
  end

  defp offered(server, names) do
    case Enum.count(names, &Wardrik.MCP.Server.offers?(server, &1)) do
      count when count == length(names) -> ""
      count -> "; only and except keep #{count}"
    end
  end

  defp sealed?(value), do: is_binary(value) and String.contains?(value, "${")

  defp listed(url, headers, req_options) do
    req =
      [
        url: url,
        headers: Map.merge(headers, %{"accept" => "application/json, text/event-stream"}),
        receive_timeout: @timeout,
        retry: false
      ]
      |> Keyword.merge(req_options)
      |> Req.new()

    initialize = %{
      protocolVersion: @version,
      capabilities: %{},
      clientInfo: %{name: "wardrik doctor", version: "0"}
    }

    with {:ok, _result, session} <- request(req, 1, "initialize", initialize, %{}),
         session = Map.put(session, "mcp-protocol-version", @version),
         :ok <- notify(req, "notifications/initialized", session),
         {:ok, %{"tools" => tools}, _session} <- request(req, 2, "tools/list", %{}, session) do
      {:ok, Enum.map(tools, & &1["name"])}
    end
  end

  defp request(req, id, method, params, session) do
    with {:ok, response} <-
           posted(req, %{jsonrpc: "2.0", id: id, method: method, params: params}, session),
         do: answered(response, session)
  end

  defp notify(req, method, session) do
    with {:ok, _response} <- posted(req, %{jsonrpc: "2.0", method: method}, session), do: :ok
  end

  defp posted(req, %{method: method} = body, session) do
    case Req.post(req, json: body, headers: session) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status} = response} ->
        {:refused, "#{method} gets #{status}#{said(response.body)}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp answered(response, session) do
    session =
      case Req.Response.get_header(response, "mcp-session-id") do
        [id | _] -> Map.put(session, "mcp-session-id", id)
        [] -> session
      end

    case message(response.body) do
      %{"result" => result} -> {:ok, result, session}
      %{"error" => %{"message" => message}} -> {:refused, "it answers #{message}"}
      _other -> {:refused, "its answer isn't MCP"}
    end
  end

  # A Streamable HTTP server answers in JSON or as an event stream.
  defp message(body) when is_map(body), do: body

  defp message(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data:" <> data -> decoded(String.trim(data))
      _line -> nil
    end)
  end

  defp message(_body), do: nil

  defp decoded(data) do
    case JSON.decode(data) do
      {:ok, message} when is_map(message) -> message
      _other -> nil
    end
  end

  defp said(%{"error" => %{"message" => message}}), do: ": #{message}"
  defp said(%{"error" => message}) when is_binary(message), do: ": #{message}"
  defp said(%{"message" => message}) when is_binary(message), do: ": #{message}"
  defp said(_body), do: ""
end
