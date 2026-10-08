defmodule Wardrik.Credo.Check.OptionsHonoured do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [functions: [:child_spec, :start_link, :init]],
    explanations: [
      check: """
      A process's start functions use the options they are given.

          # the options a host passes go nowhere
          def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}

          # they reach the process
          def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

      A host configures what it starts through the options it lists in its
      tree. A `child_spec/1`, `start_link/1` or `init/1` that ignores its
      argument leaves the host no way to set anything, so the setting moves to
      global state instead. One that takes nothing says so by taking no
      argument, or by matching `[]`.
      """,
      params: [functions: "The one-argument functions whose argument must be used."]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    functions = Params.get(params, :functions, __MODULE__)
    Credo.Code.prewalk(source_file, &walk(&1, &2, functions), ctx).issues
  end

  defp walk({op, _, [head | _]} = ast, ctx, functions) when op in [:def, :defp] do
    case call(head) do
      {name, meta, [arg]} when is_atom(name) ->
        if name in functions and ignored?(arg),
          do: {ast, Context.put_issue(ctx, issue_for(ctx, meta, name))},
          else: {ast, ctx}

      _other ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx, _functions), do: {ast, ctx}

  defp call({:when, _, [call, _guard]}), do: call
  defp call(call), do: call

  defp ignored?({:\\, _, [arg, _default]}), do: ignored?(arg)

  defp ignored?({name, _, context}) when is_atom(name) and is_atom(context),
    do: name |> Atom.to_string() |> String.starts_with?("_")

  defp ignored?(_pattern), do: false

  defp issue_for(issue_meta, meta, name) do
    format_issue(
      issue_meta,
      message: "#{name}/1 ignores its argument; use the options, or take none.",
      trigger: Atom.to_string(name),
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
