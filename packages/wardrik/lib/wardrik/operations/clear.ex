defmodule Wardrik.Operations.Clear do
  @moduledoc """
  Empties an agent's conversation, and the labels of what it read. Its files,
  schedules and config stay. Refused while it runs a turn or waits on a
  person.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Agent
  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Error

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :message

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, _caller),
    do: {:ok, Change.new(request, [{:agent_cleared, id}])}

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id}}, _caller) do
    case Agent.clear(id) do
      :ok ->
        {:ok, nil}

      {:error, :busy} ->
        {:error,
         Error.new(
           :conflict,
           "#{id} is running a turn, or waiting on a person; cancel it, or wait"
         )}

      {:error, :not_found} ->
        {:error, AgentOperation.not_found(id)}
    end
  end
end
