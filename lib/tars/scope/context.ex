defmodule Tars.Scope.Context do
  @moduledoc """
  The scope the current tool call is running under.

  `ReqLLM.Tool` callbacks receive only their arguments, so a tool that wants to
  delegate or publish events of its own reads its scope from here:

      def run(args) do
        scope = Tars.Scope.Context.current()
        Tars.Subagent.run(scope, researcher(), args["topic"], name: "researcher")
      end

  `Tars.LLM.ToolRunner` sets this before invoking a callback. Each call already
  runs in its own task, so there is one scope per process and concurrent calls
  cannot see each other's.
  """

  @key :tars_scope

  @doc "Records the scope for the current process."
  @spec put(Tars.Scope.t()) :: :ok
  def put(%Tars.Scope{} = scope) do
    Process.put(@key, scope)
    :ok
  end

  @doc "The current process's scope, or `nil` outside a tool call."
  @spec current() :: Tars.Scope.t() | nil
  def current, do: Process.get(@key)
end
