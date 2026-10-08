defmodule Wardrik.Credo.Check.NoAgent do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    explanations: [
      check: """
      Library code does not keep state in an `Agent`.

          # every read waits its turn behind every write
          Agent.get(__MODULE__, &Map.get(&1, key))

          # reads go straight to the table; the owner serializes writes
          :ets.lookup(__MODULE__, key)

      An `Agent` is a process with no behaviour of its own, so every reader
      queues on it, and its state is copied to each caller. State that many
      processes read belongs in ETS, owned by a process that does the writes;
      state one process uses belongs in that process. `Wardrik.Agent` is not
      an `Agent` and is not reported.
      """
    ]

  alias Wardrik.Credo.Code

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    aliases = Code.aliases(SourceFile.ast(source_file))
    Credo.Code.prewalk(source_file, &walk(&1, &2, aliases), ctx).issues
  end

  defp walk({:use, meta, [{:__aliases__, _, parts} | _]} = ast, ctx, aliases) do
    if Code.name(parts, aliases) == "Agent",
      do: {ast, Context.put_issue(ctx, issue_for(ctx, meta, "use Agent"))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx, aliases) do
    case Code.remote(ast, aliases) do
      {:ok, "Agent", fun, meta} ->
        {ast, Context.put_issue(ctx, issue_for(ctx, meta, "Agent.#{fun}"))}

      _other ->
        {ast, ctx}
    end
  end

  defp issue_for(issue_meta, meta, trigger) do
    format_issue(
      issue_meta,
      message: "State many processes read belongs in ETS, not an Agent.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
