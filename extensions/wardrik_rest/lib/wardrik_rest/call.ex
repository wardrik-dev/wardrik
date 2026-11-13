defmodule WardrikRest.Call do
  @moduledoc """
  Makes one call to an operation for an agent.

    * The credentials of the operation's first scheme alternative the API has sources for go in
      as its description says, with the API's `:headers` and the header arguments given.
    * A `401` tells the agent's `WardrikCore.Credentials` the token was refused, then the call is
      made once more with a fresh one.
    * A `429`, a `5xx` or no answer raises `WardrikRest.Unavailable`, so the tool runner retries.
    * Any other status is an error naming it, with the API's message.
    * An answer longer than the API's `:max_result_bytes` is cut, as JSON text.
  """

  alias WardrikCore.Context
  alias WardrikCore.Credentials
  alias WardrikCore.Keys
  alias WardrikRest.API
  alias WardrikRest.Operation

  @message_limit 500

  @enforce_keys [:api, :operation, :args, :context]
  defstruct [:api, :operation, :args, :context]

  @typedoc "One call: the operation of an API, its arguments, and the turn it's made in."
  @type t() :: %__MODULE__{
          api: API.t(),
          operation: Operation.t(),
          args: %{String.t() => term()},
          context: Context.t()
        }

  @doc "Calls `operation` of `api` with the tool's `args`, as whoever `context` acts for."
  @spec run(API.t(), Operation.t(), map(), Context.t()) ::
          {:ok, term()} | {:error, String.t()} | {:park, WardrikCore.Authorization.t()}
  def run(%API{} = api, %Operation{} = operation, args, %Context{} = context) do
    args = Map.new(args, fn {name, value} -> {to_string(name), value} end)
    attempt(%__MODULE__{api: api, operation: operation, args: args, context: context}, :first)
  end

  defp attempt(%__MODULE__{api: api} = call, attempt) do
    {:ok, schemes} = API.security(api, call.operation)

    with {:ok, secrets} <- secrets(call, schemes),
         {:ok, headers} <- headers(call) do
      call
      |> request(secrets, headers)
      |> answered(call, {attempt, credentials(api, schemes)})
    end
  end

  defp secrets(%__MODULE__{api: api} = call, schemes) do
    collect(schemes, fn scheme ->
      with {:ok, value} <- fetch(call, api.auth[scheme]),
           do: {:ok, {api.schemes[scheme], value}}
    end)
  end

  defp headers(%__MODULE__{api: api} = call) do
    collect(api.headers, fn {name, source} ->
      with {:ok, value} <- fetch(call, source), do: {:ok, {name, value}}
    end)
  end

  defp collect(items, fetch) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, done} ->
      case fetch.(item) do
        {:ok, value} -> {:cont, {:ok, [value | done]}}
        stopped -> {:halt, stopped}
      end
    end)
  end

  defp fetch(%__MODULE__{api: api, context: context}, {:credential, name}) do
    case Credentials.fetch(context, name) do
      {:ok, token} -> {:ok, to_string(token)}
      {:park, authorization} -> {:park, authorization}
      {:error, reason} -> {:error, "#{api.name} can't sign in with #{name}: #{text(reason)}"}
    end
  end

  defp fetch(%__MODULE__{api: api, context: context}, {:key, name}) do
    case Keys.fetch(context, name) do
      {:ok, key} -> {:ok, key}
      {:error, :not_found} -> {:error, "#{api.name} has no #{name} key yet."}
      {:error, reason} -> {:error, "#{api.name} can't read its #{name} key: #{text(reason)}"}
    end
  end

  defp fetch(_call, value) when is_binary(value), do: {:ok, value}

  defp credentials(api, schemes) do
    for scheme <- schemes, {:credential, name} <- [api.auth[scheme]], do: name
  end

  defp request(%__MODULE__{api: api, operation: operation, args: args}, secrets, headers) do
    given = Enum.filter(operation.parameters, &Map.has_key?(args, &1.name))

    options =
      [
        method: operation.method,
        url: api.base_url <> path(operation, args),
        params: query(given, args) ++ for({{:query, name}, value} <- secrets, do: {name, value}),
        headers: Map.new(argued(given, args) ++ headers ++ Enum.flat_map(secrets, &header/1)),
        receive_timeout: api.timeout,
        retry: false
      ] ++ body(operation, given, args) ++ api.req_options

    Req.request(options)
  end

  defp path(operation, args) do
    Regex.replace(~r/\{(\+?)([^}]+)\}/, operation.path, fn _whole, plus, name ->
      URI.encode(to_string(Map.get(args, name, "")), &kept?(&1, plus))
    end)
  end

  defp kept?(char, "+"), do: URI.char_unreserved?(char) or char == ?/
  defp kept?(char, ""), do: URI.char_unreserved?(char)

  defp query(given, args) do
    for %{in: :query, name: name} <- given, value <- List.wrap(args[name]), do: {name, value}
  end

  defp argued(given, args),
    do: for(%{in: :header, name: name} <- given, do: {name, to_string(args[name])})

  defp body(operation, given, args) do
    cond do
      payload = Enum.find(given, &(&1.in == :payload)) -> sent(operation, args[payload.name])
      Enum.any?(operation.parameters, &(&1.in == :body)) -> sent(operation, fields(given, args))
      true -> []
    end
  end

  defp fields(given, args),
    do: Map.new(for %{in: :body, name: name} <- given, do: {name, args[name]})

  defp sent(%Operation{encoding: :json}, body), do: [json: body]
  defp sent(%Operation{encoding: :form}, body), do: [form: form(body, nil)]

  # Nested as card[number]=4242 and items[0][price]=p_1, as form-encoded APIs such as Stripe's take.
  defp form(%{} = map, prefix) do
    map
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> form(value, nested(prefix, key)) end)
  end

  defp form(list, prefix) when is_list(list),
    do:
      list
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, i} -> form(value, nested(prefix, i)) end)

  defp form(nil, _prefix), do: []
  defp form(value, prefix), do: [{prefix, to_string(value)}]

  defp nested(nil, key), do: to_string(key)
  defp nested(prefix, key), do: "#{prefix}[#{key}]"

  defp header({:bearer, token}), do: [{"authorization", "Bearer " <> token}]
  defp header({{:header, name}, value}), do: [{name, value}]
  defp header({{:query, _name}, _value}), do: []

  defp answered({:ok, %Req.Response{status: status, body: body}}, call, _how)
       when status in 200..299,
       do: {:ok, sized(body, call.api.max_result_bytes)}

  defp answered({:ok, %Req.Response{status: 401}}, call, {:first, [_ | _] = names}) do
    Enum.each(names, &Credentials.refused(call.context, &1))
    attempt(call, :again)
  end

  defp answered({:ok, %Req.Response{status: 429}}, call, _how), do: unavailable(call, 429)

  defp answered({:ok, %Req.Response{status: status}}, call, _how) when status >= 500,
    do: unavailable(call, status)

  defp answered({:ok, %Req.Response{status: status, body: body}}, call, _how),
    do: {:error, "#{call.api.name} answered #{status}: #{message(body)}"}

  defp answered({:error, reason}, call, _how),
    do:
      raise(
        WardrikRest.Unavailable,
        "#{call.api.name} didn't answer: #{Exception.message(reason)}"
      )

  defp unavailable(call, status),
    do: raise(WardrikRest.Unavailable, "#{call.api.name} answered #{status}.")

  defp sized("", _limit), do: %{}

  defp sized(body, limit) do
    text = if is_binary(body), do: body, else: JSON.encode!(body)
    if byte_size(text) <= limit, do: body, else: cut(text, limit)
  end

  defp cut(text, limit) do
    kept =
      text
      |> binary_part(0, limit)
      |> String.replace_invalid("")

    kept <>
      "\n[Cut to #{limit} of #{byte_size(text)} bytes. Ask for less, such as fewer rows or fields.]"
  end

  defp message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(body) when is_binary(body), do: String.slice(body, 0, @message_limit)

  defp message(body) do
    body
    |> inspect()
    |> String.slice(0, @message_limit)
  end

  defp text(reason) when is_binary(reason), do: reason
  defp text(reason), do: inspect(reason)
end

defmodule WardrikRest.Unavailable do
  @moduledoc "Raised when a call fails in a way that a retry may fix."
  defexception [:message]
end
