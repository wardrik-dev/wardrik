defmodule WardrikHTTP.Config do
  @moduledoc """
  Where the HTTP API listens, and how long a call to a tool worker waits, as
  the application environment holds them.

      config :wardrik, WardrikHTTP, port: 4747, ip: {127, 0, 0, 1}, worker_timeout: 60_000

  `:port` is 4747 and `:ip` is loopback unless set. A daemon sets both from
  the `http` section of its `config.yaml`. `:worker_timeout` is 60 seconds
  unless set.
  """

  @default_port 4747
  @default_ip {127, 0, 0, 1}
  @default_worker_timeout :timer.seconds(60)

  @doc "The port and address to listen on."
  @spec listen() :: [port: :inet.port_number(), ip: :inet.ip_address()]
  def listen do
    settings = Application.get_env(:wardrik, WardrikHTTP, [])

    [
      port: Keyword.get(settings, :port, @default_port),
      ip: Keyword.get(settings, :ip, @default_ip)
    ]
  end

  @doc "How long a call to a tool worker waits for its answer, in milliseconds."
  @spec worker_timeout() :: pos_integer()
  def worker_timeout do
    :wardrik
    |> Application.get_env(WardrikHTTP, [])
    |> Keyword.get(:worker_timeout, @default_worker_timeout)
  end
end
