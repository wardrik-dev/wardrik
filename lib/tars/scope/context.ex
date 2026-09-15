defmodule Tars.Scope.Context do
  @moduledoc """
  The tool call in progress, and the scope it is running under.

  `ReqLLM.Tool` callbacks receive only their arguments, so a tool that wants to
  delegate, publish events of its own, or know which call it is answering reads
  that from here:

      def run(args) do
        scope = Tars.Scope.Context.current()
        Tars.Subagent.run(Tars.Scope.child(scope, name: "researcher"), args.topic)
      end

  `Tars.Workflow.call/2` does this for every workflow, so a workflow reached
  through a tool never touches this module itself.

  ## The call

  `current_call/0` is the call the model actually asked for, id and all. A tool
  with an outside effect needs the id to be idempotent — it is the only stable
  name a retry shares with its first attempt — and a host correlating a tool
  result back to a durable row needs the same id at both ends.

      def run(args) do
        %{id: id} = Tars.Scope.Context.current_call()
        Payments.charge(args.amount, idempotency_key: id)
      end

  `Tars.LLM.ToolRunner` sets both before invoking a callback. Each call already
  runs in its own task, so there is one scope and one call per process and
  concurrent calls cannot see each other's.
  """

  @scope :tars_scope
  @call :tars_tool_call

  @doc "Records the scope, and the call it is running, for the current process."
  @spec put(Tars.Scope.t(), Tars.Tool.call() | nil) :: :ok
  def put(%Tars.Scope{} = scope, call \\ nil) do
    Process.put(@scope, scope)
    Process.put(@call, call)
    :ok
  end

  @doc "The current process's scope, or `nil` outside a tool call."
  @spec current() :: Tars.Scope.t() | nil
  def current, do: Process.get(@scope)

  @doc "The call the current process is answering, or `nil` outside a tool call."
  @spec current_call() :: Tars.Tool.call() | nil
  def current_call, do: Process.get(@call)

  @doc """
  The id of the call the current process is answering, or `nil`.

  What a tool with an outside effect uses as its idempotency key.
  """
  @spec current_call_id() :: String.t() | nil
  def current_call_id do
    case current_call() do
      %{id: id} -> id
      nil -> nil
    end
  end
end
