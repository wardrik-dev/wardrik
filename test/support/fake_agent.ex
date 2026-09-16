defmodule Tars.Test.FakeAgent do
  @moduledoc """
  Stands in for a `Tars.Agent` behind a view that is driven by events.

  Answers the calls `TarsTUI.App` makes when it attaches as an idle agent with
  an empty conversation, and forwards every cast to its owner as the
  `{:"$gen_cast", message}` it arrived as.
  """
  use GenServer

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call(:status, _from, owner),
    do: {:reply, %{state: :idle, pending: 0, model: "test:model"}, owner}

  def handle_call(:parked, _from, owner), do: {:reply, [], owner}
  def handle_call(:get_context, _from, owner), do: {:reply, ReqLLM.Context.new(), owner}

  def handle_call(:snapshot, _from, owner) do
    {:reply,
     %{
       status: %{state: :idle, pending: 0, model: "test:model"},
       context: ReqLLM.Context.new(),
       parked: [],
       generation: inspect(self()),
       trace_id: nil
     }, owner}
  end

  def handle_call({:decide, decisions}, _from, owner) do
    send(owner, {:"$gen_cast", {:resume, decisions}})
    {:reply, :ok, owner}
  end

  @impl true
  def handle_cast(message, owner) do
    send(owner, {:"$gen_cast", message})
    {:noreply, owner}
  end
end
