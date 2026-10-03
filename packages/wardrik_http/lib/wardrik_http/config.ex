defmodule WardrikHTTP.Config do
  @moduledoc """
  Where the HTTP API listens, and how long a call to a tool worker waits, as
  the application environment holds them.

      config :wardrik_http, WardrikHTTP, port: 4747, ip: {127, 0, 0, 1}, worker_timeout: 60_000

  `:port` is 4747 and `:ip` is loopback unless set. A daemon sets both from
  the `http` section of its `config.yaml`. `:worker_timeout` is 60 seconds
  unless set. `:trusted_workers` says tool workers' answers are the
  deployment's own, so a call to one does not taint its run; `false` unless
  set.

      config :wardrik_http, WardrikHTTP.Access, grace: 1_000, sweep: 15_000

  How `WardrikHTTP.Access` ends the holders of a revoked token, and how often
  it reads the tokens held again, in milliseconds; those are the defaults.
  """

  @default_port 4747
  @default_ip {127, 0, 0, 1}
  @default_worker_timeout :timer.seconds(60)
  @default_grace 1_000
  @default_sweep :timer.seconds(15)

  @doc "The port and address to listen on."
  @spec listen() :: [port: :inet.port_number(), ip: :inet.ip_address()]
  def listen do
    settings = Application.get_env(:wardrik_http, WardrikHTTP, [])

    [
      port: Keyword.get(settings, :port, @default_port),
      ip: Keyword.get(settings, :ip, @default_ip)
    ]
  end

  @doc "Whether what tool workers answer is the deployment's own, rather than content from outside."
  @spec trusted_workers?() :: boolean()
  def trusted_workers? do
    :wardrik_http
    |> Application.get_env(WardrikHTTP, [])
    |> Keyword.get(:trusted_workers, false)
  end

  @doc "How long a call to a tool worker waits for its answer, in milliseconds."
  @spec worker_timeout() :: pos_integer()
  def worker_timeout do
    :wardrik_http
    |> Application.get_env(WardrikHTTP, [])
    |> Keyword.get(:worker_timeout, @default_worker_timeout)
  end

  @doc """
  How long the holders of a revoked record have to end themselves, and how
  often held records are read again, in milliseconds; see `WardrikHTTP.Access`.
  """
  @spec access(:grace | :sweep) :: pos_integer()
  def access(:grace),
    do:
      :wardrik_http
      |> Application.get_env(WardrikHTTP.Access, [])
      |> Keyword.get(:grace, @default_grace)

  def access(:sweep),
    do:
      :wardrik_http
      |> Application.get_env(WardrikHTTP.Access, [])
      |> Keyword.get(:sweep, @default_sweep)
end
