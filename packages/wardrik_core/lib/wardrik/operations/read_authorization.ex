defmodule Wardrik.Operations.ReadAuthorization do
  @moduledoc """
  Where a person authorizes the call an interrupt waits on: the page, and the
  code to enter where one is needed. It is read only by a caller who may
  decide the call, since the link is kept out of every event.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Query

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Error
  alias Wardrik.Resource

  @enforce_keys [:agent, :interrupt]
  defstruct [:agent, :interrupt]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), interrupt: String.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :decide

  @impl Wardrik.Query
  def run(%__MODULE__{agent: id, interrupt: interrupt}, _caller) do
    case Agent.parked(id) do
      {:error, :not_found} -> {:error, AgentOperation.not_found(id)}
      calls -> calls |> link(interrupt) |> answer(id, interrupt)
    end
  end

  defp link(calls, interrupt) do
    case Enum.find(calls, fn {call, _prompt} -> call.id == interrupt end) do
      {%{link: %{url: _url} = link}, _prompt} -> {:ok, link}
      {_call, _prompt} -> :none
      nil -> :not_waiting
    end
  end

  defp answer({:ok, link}, _id, _interrupt), do: {:ok, Resource.authorization(link)}

  defp answer(:none, _id, interrupt),
    do: {:error, Error.new(:not_found, "#{interrupt} waits on no authorization.")}

  defp answer(:not_waiting, id, interrupt),
    do: {:error, Error.new(:not_found, "#{id} is not waiting on #{interrupt}.")}
end
