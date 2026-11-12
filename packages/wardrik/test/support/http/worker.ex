defmodule Wardrik.Test.HTTP.Worker do
  @moduledoc "A tool worker's socket for a test: it sends the test each message, and sends what it's told."
  use WebSockex

  def start(url, secret, test),
    do:
      WebSockex.start(url, __MODULE__, test,
        extra_headers: [{"authorization", "Bearer " <> secret}],
        handle_initial_conn_failure: true
      )

  def send_message(worker, message),
    do: WebSockex.send_frame(worker, {:text, JSON.encode!(message)})

  @impl WebSockex
  def handle_frame({:text, text}, test) do
    send(test, {:worker, JSON.decode!(text)})
    {:ok, test}
  end

  @impl WebSockex
  def handle_disconnect(%{reason: reason}, test) do
    send(test, {:worker_closed, reason})
    {:ok, test}
  end
end
