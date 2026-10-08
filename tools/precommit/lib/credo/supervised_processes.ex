defmodule Wardrik.Credo.Check.SupervisedProcesses do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      calls: ["spawn", "spawn_link", "spawn_monitor", "Process.spawn", "Task.start"]
    ],
    explanations: [
      check: """
      A process is started under a supervisor.

          # nobody knows it is running, or that it died
          spawn(fn -> System.cmd("open", [url]) end)

          # the package's own supervisor holds it
          Task.Supervisor.start_child(WardrikOAuth.Tasks, fn -> System.cmd("open", [url]) end)

      A process started outside the tree is never shut down with it, its crash
      is logged nowhere it would be looked for, and nothing can list it. Start
      it under a `Task.Supervisor` or `DynamicSupervisor` of the package's own.
      Where a bare process is the point, such as a watcher that must not be
      linked to anything, say why beside it and disable the check there.
      """,
      params: [calls: "The calls reported, as `name` for Kernel or `Module.name`."]
    ]

  alias Wardrik.Credo.Code

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    calls = Params.get(params, :calls, __MODULE__)
    ast = SourceFile.ast(source_file)
    known = {Code.aliases(ast), Code.defined(ast)}
    Credo.Code.prewalk(source_file, &walk(&1, &2, calls, known), ctx).issues
  end

  # A bare call is Kernel's only at the arities Kernel has, and only where the
  # module defines no function of its own by that name.
  defp walk({name, meta, args} = ast, ctx, calls, {_aliases, defined})
       when is_atom(name) and is_list(args) do
    if Atom.to_string(name) in calls and length(args) in [1, 3] and
         not MapSet.member?(defined, {name, length(args)}),
       do: {ast, Context.put_issue(ctx, issue_for(ctx, meta, Atom.to_string(name)))},
       else: {Code.bodies_only(ast), ctx}
  end

  defp walk(ast, ctx, calls, {aliases, _defined}) do
    with {:ok, module, fun, meta} <- Code.remote(ast, aliases),
         trigger = "#{module}.#{fun}",
         true <- trigger in calls do
      {ast, Context.put_issue(ctx, issue_for(ctx, meta, trigger))}
    else
      _other -> {ast, ctx}
    end
  end

  defp issue_for(issue_meta, meta, trigger) do
    format_issue(
      issue_meta,
      message: "#{trigger} starts a process outside the tree; start it under a supervisor.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
