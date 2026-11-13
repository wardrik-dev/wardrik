defmodule WardrikDaemon.Client do
  @moduledoc """
  Calls a daemon's HTTP API. The `wardrik` command uses it.

      client = %WardrikDaemon.Client{url: "http://127.0.0.1:4747", secret: secret}
      {:ok, answer} = WardrikDaemon.Client.run(client, "agents.list", %{})

  It takes every `WardrikProtocol` operation and the daemon's own. See `WardrikDaemon.HTTP`.
  """

  @enforce_keys [:url, :secret]
  defstruct [:url, :secret, req_options: []]

  @type t() :: %__MODULE__{url: String.t(), secret: String.t(), req_options: keyword()}

  @typedoc "Why an operation failed: the protocol's error type, and its message."
  @type error() :: {:error, String.t(), String.t()}

  @doc "Runs the operation `id` with `input`. Returns its answer, or `nil` if it answers nothing."
  @spec run(t(), String.t(), map()) :: {:ok, map() | nil} | error()
  def run(client, id, input) do
    operation = operation(id)
    {path, rest} = path(operation, input)

    client
    |> request(operation.method, path, rest)
    |> Req.request()
    |> answered(client)
  end

  @doc """
  Opens operation `id`'s events as a stream. Read them with `next/2`. Nothing after it returns is missed.
  """
  @spec open(t(), String.t(), map()) :: {:ok, Req.Response.t()} | error()
  def open(client, id, input) do
    operation = operation(id)
    {path, rest} = path(operation, input)

    client
    |> request("get", path, rest)
    |> Req.merge(headers: [accept: "text/event-stream"], into: :self, receive_timeout: :infinity)
    |> Req.request()
    |> opened(client)
  end

  @doc "Returns the next events on an opened stream. Waits at most `timeout`. Returns `:done` once the stream ends."
  @spec next(Req.Response.t(), timeout()) :: {:ok, [map()], Req.Response.t()} | :done | :timeout
  def next(response, timeout) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, chunks} -> chunked(response, chunks)
          :unknown -> next(response, timeout)
        end
    after
      timeout -> :timeout
    end
  end

  @doc "Stops reading an opened stream."
  @spec close(Req.Response.t()) :: :ok
  def close(response) do
    _cancelled = Req.cancel_async_response(response)
    :ok
  end

  defp operation(id), do: WardrikDaemon.HTTP.operation(id) || WardrikProtocol.operation(id)

  defp request(client, method, path, input) do
    [
      method: String.to_existing_atom(method),
      base_url: client.url,
      url: path,
      auth: {:bearer, client.secret},
      retry: false
    ]
    |> Keyword.merge(body(method, input))
    |> Req.new()
    |> Req.merge(client.req_options)
  end

  defp body(method, input) when method in ["get", "delete"], do: [params: query(input)]
  defp body(_method, input), do: [json: input]

  defp query(input) do
    Enum.flat_map(input, fn
      {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
      {key, value} -> [{key, value}]
    end)
  end

  # An operation on a conversation goes to its conversation's route, where it has one.
  defp path(operation, input) do
    template = template(operation, input)
    in_path = for [_whole, name] <- Regex.scan(~r/\{(\w+)\}/, template), do: name

    path =
      Enum.reduce(in_path, template, fn name, path ->
        String.replace(path, "{#{name}}", segment(input[name]))
      end)

    {path, Map.drop(input, in_path)}
  end

  defp template(%{conversation: route}, %{"conversation" => _conversation}) when is_binary(route),
    do: route

  defp template(%{path: path}, _input), do: path

  defp segment(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp answered({:ok, %Req.Response{status: status, body: body}}, _client)
       when status in 200..299,
       do: {:ok, if(body == "", do: nil, else: body)}

  defp answered(
         {:ok, %Req.Response{body: %{"error" => %{"type" => type, "message" => message}}}},
         _client
       ),
       do: {:error, type, message}

  defp answered({:ok, %Req.Response{status: status}}, _client),
    do: {:error, "internal", "The daemon answered #{status}."}

  defp answered({:error, _reason}, client), do: unreachable(client)

  defp opened({:ok, %Req.Response{status: 200} = response}, _client),
    do: {:ok, Req.Response.put_private(response, :sse, "")}

  defp opened({:ok, %Req.Response{} = response}, client) do
    body =
      Enum.join(
        for {:data, data} <- elem(Req.parse_message(response, receive_body()), 1), do: data
      )

    answered({:ok, %{response | body: decoded(body)}}, client)
  end

  defp opened(other, client), do: answered(other, client)

  defp receive_body do
    receive do
      message -> message
    after
      5_000 -> nil
    end
  end

  defp decoded(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _not_json} -> body
    end
  end

  defp unreachable(client),
    do:
      {:error, "unavailable",
       "Nothing answers at #{client.url}. Start the daemon with `wardrik start`."}

  defp chunked(response, chunks) do
    if :done in chunks do
      :done
    else
      data = for {:data, data} <- chunks, into: Req.Response.get_private(response, :sse), do: data
      {frames, rest} = frames(data)
      {:ok, Enum.flat_map(frames, &event/1), Req.Response.put_private(response, :sse, rest)}
    end
  end

  defp frames(buffer) do
    parts = String.split(buffer, "\n\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp event(frame) do
    data = for "data: " <> line <- String.split(frame, "\n"), into: "", do: line

    case JSON.decode(data) do
      {:ok, event} -> [event]
      {:error, _not_json} -> []
    end
  end
end
