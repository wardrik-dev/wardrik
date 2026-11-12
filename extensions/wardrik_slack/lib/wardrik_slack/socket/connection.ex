defmodule WardrikSlack.Socket.Connection do
  @moduledoc false

  use WebSockex

  alias WardrikSlack.Socket

  @spec start_link(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, owner), do: WebSockex.start_link(url, __MODULE__, owner)

  @impl WebSockex
  def handle_frame({:text, text}, owner) do
    case Socket.envelope(text) do
      :hello ->
        send(owner, :hello)
        {:ok, owner}

      :disconnect ->
        {:close, owner}

      {:ack, id, :ignore} ->
        {:reply, ack_frame(id), owner}

      {:ack, id, work} ->
        send(owner, work)
        {:reply, ack_frame(id), owner}

      {:ack_after, id, {:message, callback}} ->
        send(owner, {:message, callback, {self(), id}})
        {:ok, owner}

      :ignore ->
        {:ok, owner}
    end
  end

  def handle_frame(_frame, owner), do: {:ok, owner}

  @spec ack(pid(), String.t()) :: :ok | {:error, term()}
  def ack(connection, id), do: WebSockex.send_frame(connection, ack_frame(id))

  defp ack_frame(id), do: {:text, JSON.encode!(%{envelope_id: id})}
end
