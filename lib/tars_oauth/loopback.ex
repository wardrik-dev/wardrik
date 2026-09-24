defmodule TarsOAuth.Loopback do
  @moduledoc """
  The one page an authorization server redirects back to, served on loopback.

      config :tars, TarsOAuth, redirect: [port: 4599]

  A single binary has nowhere on the public internet to send a code, and RFC
  8252 says a native application should not need one: the browser is on the
  same machine, so `http://127.0.0.1:4599/callback` is the redirect URI to
  register with a provider.

  It listens on loopback only, answers one request with a page telling the
  person to go back to their agent, and hands the code to `TarsOAuth.finish/2`.
  Anything that is not the callback path gets a 404, and a callback carrying
  no state gets a 400.

  A port another process holds is tried again every five seconds, so of
  several nodes on one machine the first to start listens, and another takes
  the port over when that one stops. `TarsOAuth.finish/2` finds a flow any
  node of the cluster started.

  A deployment with a web surface of its own registers that instead and calls
  `TarsOAuth.finish/2` from its own controller; then nothing here runs.
  """

  use GenServer

  require Logger

  @default_port 4599
  @path "/callback"
  @retry :timer.seconds(5)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The redirect URI this listener answers on."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: "http://127.0.0.1:#{port()}#{@path}"

  @doc "The port it listens on."
  @spec port() :: :inet.port_number()
  def port, do: Keyword.get(TarsOAuth.Config.redirect(), :port, @default_port)

  @impl GenServer
  def init(opts) do
    port = Keyword.get(opts, :port, port())
    retry = Keyword.get(opts, :retry, @retry)
    {:ok, listen(%{port: port, retry: retry, socket: nil}, :first)}
  end

  @impl GenServer
  def handle_info(:listen, %{socket: nil} = state), do: {:noreply, listen(state, :again)}
  def handle_info(:listen, state), do: {:noreply, state}

  def handle_info({:answered, _connection}, %{socket: socket} = state) do
    accept(socket)

    {:noreply, state}
  end

  defp listen(%{port: port} = state, attempt) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        if attempt == :again, do: Logger.info("OAuth loopback listens on #{port} now")
        accept(socket)
        %{state | socket: socket}

      {:error, reason} ->
        if attempt == :first do
          Logger.warning(
            "OAuth loopback could not listen on #{port}: #{inspect(reason)}. " <>
              "It is tried again every #{div(state.retry, 1000)}s"
          )
        end

        Process.send_after(self(), :listen, state.retry)
        state
    end
  end

  defp accept(socket) do
    listener = self()

    spawn_link(fn ->
      case :gen_tcp.accept(socket) do
        {:ok, connection} ->
          send(listener, {:answered, connection})
          serve(connection)

        {:error, reason} ->
          send(listener, {:answered, reason})
      end
    end)
  end

  defp serve(connection) do
    with {:ok, request} <- :gen_tcp.recv(connection, 0, :timer.seconds(10)),
         {:ok, target} <- request_target(request) do
      target |> answer() |> then(&:gen_tcp.send(connection, &1))
    else
      _unreadable -> :gen_tcp.send(connection, response(400, "Tars could not read that request."))
    end

    :gen_tcp.close(connection)
  end

  defp request_target(request) do
    case Regex.run(~r{^GET ([^\s]+) HTTP/1\.[01]}, request) do
      [_match, target] -> {:ok, target}
      nil -> :error
    end
  end

  defp answer(target) do
    uri = URI.parse(target)

    if uri.path == @path,
      do: (uri.query || "") |> URI.decode_query() |> complete(),
      else: response(404, "Nothing here.")
  end

  defp complete(%{"error" => error} = params) do
    response(400, "#{error}: #{params["error_description"] || "no reason given"}")
  end

  defp complete(%{"code" => code, "state" => state}) do
    case TarsOAuth.finish(state, code) do
      {:ok, provider} -> response(200, "#{provider} is connected. Go back to your agent.")
      {:error, reason} -> response(400, "That did not work: #{inspect(reason)}")
    end
  end

  defp complete(_params), do: response(400, "That callback carried no code.")

  defp response(status, message) do
    body = """
    <!doctype html><meta charset="utf-8"><title>Tars</title>
    <body style="font: 16px system-ui; margin: 4rem auto; max-width: 32rem">
    <p>#{message}</p>
    """

    """
    HTTP/1.1 #{status} #{reason(status)}\r
    content-type: text/html; charset=utf-8\r
    content-length: #{byte_size(body)}\r
    connection: close\r
    \r
    #{body}
    """
  end

  defp reason(200), do: "OK"
  defp reason(400), do: "Bad Request"
  defp reason(404), do: "Not Found"
end
