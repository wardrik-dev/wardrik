defmodule Wardrik.Credo.Check.NoSelfSend do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      A process does not send itself a message to carry on with its work.

          # a message, which waits behind anything already in the mailbox
          send(self(), :load)
          {:ok, state}

          # a continue, which runs next, before any message
          {:ok, state, {:continue, :load}}

      A message to self lands behind whatever is already queued, so a call can
      be handled between the step that sent it and the step it starts, and an
      `init` that sends one leaves a gap where the process answers before it
      is ready. A continue runs before the next message. A timer,
      `Process.send_after/3`, waits on purpose and is not reported.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({:send, meta, [target, _message]} = ast, ctx),
    do: {ast, maybe_issue(ctx, meta, target, "send")}

  defp walk({{:., meta, [{:__aliases__, _, [:Kernel]}, :send]}, _, [target, _]} = ast, ctx),
    do: {ast, maybe_issue(ctx, meta, target, "Kernel.send")}

  defp walk({{:., meta, [{:__aliases__, _, [:Process]}, :send]}, _, [target, _, _]} = ast, ctx),
    do: {ast, maybe_issue(ctx, meta, target, "Process.send")}

  defp walk(ast, ctx), do: {ast, ctx}

  defp maybe_issue(ctx, meta, {:self, _, args}, trigger) when args in [[], nil],
    do: Context.put_issue(ctx, issue_for(ctx, meta, trigger))

  defp maybe_issue(ctx, _meta, _target, _trigger), do: ctx

  defp issue_for(issue_meta, meta, trigger) do
    format_issue(
      issue_meta,
      message: "A process carries on with a continue, not a message to itself.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
