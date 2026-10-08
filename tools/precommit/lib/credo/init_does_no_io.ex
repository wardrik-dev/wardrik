defmodule Wardrik.Credo.Check.InitDoesNoIO do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      calls: [
        "WardrikStore.get",
        "WardrikStore.put",
        "WardrikStore.lookup",
        "WardrikStore.delete",
        "WardrikStore.keys",
        "WardrikStore.check",
        "Wardrik.Event.Log.Writer",
        "Req",
        "File",
        "System.cmd",
        "Port",
        "Node.connect",
        "GenServer.call",
        ":inet",
        ":gen_tcp",
        ":httpc",
        ":erpc",
        ":rpc",
        ":global.trans"
      ]
    ],
    explanations: [
      check: """
      `init/1` sets a process up; slow work comes after it, in a continue.

          # whoever starts it waits on the store, and so does its supervisor
          def init(state), do: {:ok, %{state | log: Writer.open(state.log)}}

          # it answers at once and opens the log before any message
          def init(state), do: {:ok, state, {:continue, :open}}
          def handle_continue(:open, state), do: {:noreply, %{state | log: Writer.open(state.log)}}

      A supervisor starts its children one at a time and waits on each
      `init`, so a store read, a network call or a call to another process
      there holds up every sibling after it, and every restart. A call made in
      `init` to a process that is itself waiting on this one never returns.
      Do the work in `handle_continue/2`, which runs before any message. Where
      a process must not answer until the work is done, say why beside it and
      disable the check there.
      """,
      params: [calls: "The modules, or `Module.name` calls, `init/1` may not make."]
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

  defp walk({:def, _, [head, body]} = ast, ctx, calls, aliases) do
    if init?(head) do
      {_body, ctx} = Macro.prewalk(body, ctx, &call(&1, &2, calls, aliases))
      {ast, ctx}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx, _calls, _aliases), do: {ast, ctx}

  defp init?({:when, _, [head, _guard]}), do: init?(head)
  defp init?({:init, _, [_arg]}), do: true
  defp init?(_head), do: false

  defp call(ast, ctx, calls, aliases) do
    with {:ok, module, fun, meta} <- Code.remote(ast, aliases),
         trigger = "#{module}.#{fun}",
         true <- module in calls or trigger in calls do
      {ast, Context.put_issue(ctx, issue_for(ctx, meta, trigger))}
    else
      _other -> {ast, ctx}
    end
  end

  defp issue_for(issue_meta, meta, trigger) do
    format_issue(
      issue_meta,
      message: "#{trigger} in init/1 holds up the supervisor; do it in a continue.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
