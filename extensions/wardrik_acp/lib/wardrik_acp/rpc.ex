defmodule WardrikACP.RPC do
  @moduledoc false

  @type message() ::
          {:request, term(), String.t(), map()}
          | {:notification, String.t(), map()}
          | {:result, term(), term()}
          | {:error, term(), map()}

  @doc "Encodes a request, as one line."
  @spec request(term(), String.t(), map()) :: iodata()
  def request(id, method, params),
    do: line(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  @doc "Encodes a notification, as one line."
  @spec notification(String.t(), map()) :: iodata()
  def notification(method, params),
    do: line(%{"jsonrpc" => "2.0", "method" => method, "params" => params})

  @doc "Encodes the result of the request `id`, as one line."
  @spec result(term(), term()) :: iodata()
  def result(id, result), do: line(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

  @doc "Encodes an error answering the request `id`, as one line."
  @spec error(term(), integer(), String.t()) :: iodata()
  def error(id, code, message),
    do:
      line(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}})

  @doc """
  Splits `buffer` at each line feed. Returns the messages in its complete lines, and the rest.
  A line that isn't a JSON-RPC message is skipped.
  """
  @spec split(binary()) :: {[message()], binary()}
  def split(buffer) do
    {lines, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {Enum.flat_map(lines, &decode/1), rest}
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = message} -> message(message)
      _skipped -> []
    end
  end

  defp message(%{"id" => id, "method" => method} = message),
    do: [{:request, id, method, Map.get(message, "params") || %{}}]

  defp message(%{"method" => method} = message),
    do: [{:notification, method, Map.get(message, "params") || %{}}]

  defp message(%{"id" => id, "error" => error}), do: [{:error, id, error}]
  defp message(%{"id" => id} = message), do: [{:result, id, Map.get(message, "result")}]
  defp message(_other), do: []

  defp line(message), do: [JSON.encode!(message), ?\n]
end
