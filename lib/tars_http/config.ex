defmodule TarsHTTP.Config do
  @moduledoc """
  Where the HTTP API listens, as the application environment holds it.

      config :tars, TarsHTTP, port: 4747, ip: {127, 0, 0, 1}

  `:port` is 4747 and `:ip` is loopback unless set. A daemon sets both from
  the `http` section of its `config.yaml`.
  """

  @default_port 4747
  @default_ip {127, 0, 0, 1}

  @doc "The port and address to listen on."
  @spec listen() :: [port: :inet.port_number(), ip: :inet.ip_address()]
  def listen do
    settings = Application.get_env(:tars, TarsHTTP, [])

    [
      port: Keyword.get(settings, :port, @default_port),
      ip: Keyword.get(settings, :ip, @default_ip)
    ]
  end
end
