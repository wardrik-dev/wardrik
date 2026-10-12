defmodule Wardrik.Credo.Check.NoScans do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      calls: [
        "Supervisor.which_children",
        "DynamicSupervisor.which_children",
        "PartitionSupervisor.which_children",
        "Registry.select",
        "Group.global_members",
        ":global.registered_names"
      ]
    ],
    explanations: [
      check: """
      A process is found by its key, not by listing every process and
      filtering.

          # reads every trigger on every node to find one agent's
          for {key, _pid, _meta} <- Group.global_members(group), String.starts_with?(key, prefix), do: key

          # reads the agent's own group
          Group.members(group, "agents/" <> id)

      Listing children, a registry or a cluster-wide group costs as much as
      there are processes, and on every node a group spans; done per request,
      or per row of a listing, it grows with the whole fleet. Register each
      process under the key it is looked up by. A listing that really is of
      everything, such as a status page, says why beside the call and disables
      the check there.
      """,
      params: [calls: "The calls reported, as `Module.name`."]
    ]

  alias Wardrik.Credo.Code

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    calls = Params.get(params, :calls, __MODULE__)
    aliases = Code.aliases(SourceFile.ast(source_file))
    Credo.Code.prewalk(source_file, &walk(&1, &2, calls, aliases), ctx).issues
  end

  defp walk(ast, ctx, calls, aliases) do
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
      message: "#{trigger} lists every process; look one up by its key.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
