defmodule Wardrik.Operations.Deliver do
  @moduledoc """
  Hands a request from outside to one of an agent's triggers, which checks
  it and asks the agent; see `Wardrik.Triggers`. The answer says whether the
  agent was asked, or had been asked about the same request before.

  The caller's grant must let it message the agent, so a surface that takes
  such requests from anyone grants just that, on just that agent; the
  trigger decides whether the request is the sender's. One that is not is
  answered as one to no such trigger, so a request tells its sender nothing
  of the triggers another org's agents have.
  """

  @behaviour Wardrik.AgentOperation
  @behaviour Wardrik.Command

  alias Wardrik.Change
  alias Wardrik.Error
  alias Wardrik.Triggers

  @enforce_keys [:agent, :trigger, :headers, :body]
  defstruct [:agent, :trigger, :headers, :body]

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          trigger: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @impl Wardrik.AgentOperation
  def subject(%__MODULE__{agent: id}), do: id

  @impl Wardrik.AgentOperation
  def action, do: :message

  @impl Wardrik.Command
  def plan(%__MODULE__{} = request, _caller) do
    with {:ok, _module} <- Triggers.module(), do: {:ok, Change.new(request)}
  end

  @impl Wardrik.Command
  def make(%Change{request: %__MODULE__{} = request} = change, _caller) do
    with {:ok, module} <- Triggers.module() do
      case module.deliver(request.agent, request.trigger, %{
             headers: request.headers,
             body: request.body
           }) do
        {:ok, status} ->
          {:ok, %{"delivery" => %{"status" => Atom.to_string(status)}}, change.effect}

        {:error, :not_found} ->
          {:error, no_trigger(request)}

        {:error, :forbidden, _message} ->
          {:error, no_trigger(request)}

        {:error, :unavailable, message} ->
          {:error, Error.new(:unavailable, message)}
      end
    end
  end

  defp no_trigger(request),
    do: Error.new(:not_found, "#{request.agent} has no trigger #{request.trigger} to deliver to.")

  defimpl Wardrik.Effect do
    def preview(%{agent: agent, trigger: trigger}),
      do: %{"delivering" => %{"agent" => to_string(agent), "trigger" => trigger}}

    def audit(_deliver), do: []
  end
end
