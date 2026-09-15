defmodule Tars.Console do
  @moduledoc """
  Renders one agent's stream and tool events to stdout.

      {:ok, _pid} = Tars.Console.start_link(agent_id: "acme/jon/assistant")

  Just a subscriber. Several can run at once alongside other listeners, and
  none of them are known to `Tars.Agent` or `Tars.LLM.Turn`.
  """
  use GenServer

  alias Tars.Event

  def start_link(opts) do
    {agent_id, opts} = Keyword.pop!(opts, :agent_id)
    GenServer.start_link(__MODULE__, agent_id, opts)
  end

  @impl true
  def init(agent_id) do
    :ok = Event.Bus.subscribe(agent_id)
    {:ok, %{agent_id: agent_id}}
  end

  @impl true
  def handle_info(%Event{payload: {:result, text}}, state) when is_binary(text) do
    IO.write(text)
    {:noreply, state}
  end

  def handle_info(%Event{payload: {:thinking, text}}, state) when is_binary(text) do
    IO.write(text)
    {:noreply, state}
  end

  def handle_info(%Event{payload: {:tool_started, _id, name}}, state) do
    IO.write("\n  → #{name}\n")
    {:noreply, state}
  end

  def handle_info(%Event{payload: {:tool_finished, _id, name, {:ok, _output}}}, state) do
    IO.write("  ✓ #{name}\n")
    {:noreply, state}
  end

  def handle_info(%Event{payload: {:tool_finished, _id, name, {:error, reason}}}, state) do
    IO.write("  ✗ #{name}: #{inspect(reason)}\n")
    {:noreply, state}
  end

  def handle_info(%Event{payload: {:turn_finished, _messages}}, state) do
    IO.write("\n")
    {:noreply, state}
  end

  def handle_info(%Event{payload: {:turn_failed, reason}}, state) do
    IO.write("\n  turn failed: #{inspect(reason)}\n")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
