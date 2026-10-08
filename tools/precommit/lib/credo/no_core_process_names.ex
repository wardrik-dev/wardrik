defmodule Wardrik.Credo.Check.NoCoreProcessNames do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [names: ["Wardrik.Tasks"]],
    explanations: [
      check: """
      A package does not name a process that core starts.

          # reaching core's supervisors
          Task.Supervisor.start_child(Wardrik.Tasks.supervisor(), fun)

          # a supervisor of the package's own
          Task.Supervisor.start_child(WardrikMCP.TaskSupervisor, fun)

      A registered name, or the function that names it, ties a package to a
      process only core's supervision tree starts, so it runs only where that
      tree is already up. The package starts what it needs under its own
      supervisor.
      """,
      params: [names: "The registered names a package may not refer to."]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    names = Params.get(params, :names, __MODULE__)

    Credo.Code.prewalk(source_file, &walk(&1, &2, names), ctx).issues
  end

  defp walk({:__aliases__, meta, parts} = ast, ctx, names) do
    if Enum.all?(parts, &is_atom/1) and Enum.join(parts, ".") in names do
      {ast, Context.put_issue(ctx, issue_for(ctx, meta, Enum.join(parts, ".")))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx, _names), do: {ast, ctx}

  defp issue_for(issue_meta, meta, name) do
    format_issue(
      issue_meta,
      message: "#{name} is core's process; a package starts and names its own.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
