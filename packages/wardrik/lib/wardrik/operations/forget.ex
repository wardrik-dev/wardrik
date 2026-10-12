defmodule Wardrik.Operations.Forget do
  @moduledoc """
  Removes an agent, with everything it had. The host's `Wardrik.Definition`
  is asked first, and may refuse; the agent is forgotten where one runs, or
  where a definition of it was kept.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.AgentOperation
  alias Wardrik.Change
  alias Wardrik.Definition
  alias Wardrik.Error
  alias Wardrik.Fleet

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t()}

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :define

  @impl Wardrik.Command
  def plan(%__MODULE__{agent: id} = request, _caller) do
    with {:ok, _module} <- definitions(),
         do: {:ok, Change.new(request, [{:agent_forgotten, id}])}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{agent: id}}, _caller) do
    with {:ok, module} <- definitions(),
         {:ok, kept} <- delete(module, id) do
      running = Fleet.lookup(id)
      if running, do: :ok = Fleet.forget(id)

      if running || kept,
        do: {:ok, nil},
        else: {:error, AgentOperation.not_found(id)}
    end
  end

  defp definitions do
    case Definition.module(:delete) do
      {:ok, module} -> {:ok, module}
      :unsupported -> {:error, Error.new(:unsupported, "This server does not delete agents.")}
    end
  end

  # Whether a definition was kept, and is gone.
  defp delete(module, id) do
    case module.delete(id) do
      :ok -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
    end
  end
end
