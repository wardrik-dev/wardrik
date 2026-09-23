defmodule Tars.Credo.Check.NoCoreProcessNames do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [names: ["Tars.TaskSupervisor"]],
    explanations: [
      check: """
      A package does not name a process that core starts.

          # reaching core's supervisor by name
          Task.Supervisor.start_child(Tars.TaskSupervisor, fun)

          # a supervisor of the package's own
          Task.Supervisor.start_child(TarsMCP.TaskSupervisor, fun)

      A registered name is not a function call, so no dependency rule sees it,
      and a package that holds one only runs where core's supervision tree is
      already up. The package starts what it needs under its own supervisor.
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
