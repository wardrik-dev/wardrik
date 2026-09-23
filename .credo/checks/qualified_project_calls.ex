defmodule Tars.Credo.Check.QualifiedProjectCalls do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [namespaces: ["Tars"]],
    explanations: [
      check: """
      A call into a project module is written with the module fully qualified,
      or through an alias of that exact module. It is not written through an
      alias of a parent namespace.

          # through a parent alias
          alias Tars.LLM
          LLM.Turn.yield(pid)

          # the module itself
          alias Tars.LLM.Turn
          Turn.yield(pid)

          # or spelled out
          Tars.LLM.Turn.yield(pid)

      The architecture policy in `.reach.exs` is checked against the call graph
      `mix reach.check --arch` builds, and that graph records the target of a
      call as it is written. `LLM.Turn.yield/1` is not a module under `Tars.*`,
      so a rule about `Tars.LLM.Turn` never sees the call. Every rule keyed on a
      callee module has the same gap, and this check closes it at the source.
      """,
      params: [
        namespaces: "The first segment of the module namespaces the rule applies to."
      ]
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    namespaces = Params.get(params, :namespaces, __MODULE__)
    aliases = Credo.Code.prewalk(source_file, &collect(&1, &2, namespaces), %{})

    if map_size(aliases) == 0 do
      []
    else
      Credo.Code.prewalk(source_file, &walk(&1, &2, aliases), ctx).issues
    end
  end

  # alias Tars.LLM, as: L
  defp collect(
         {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [as]}]]} = ast,
         acc,
         ns
       ) do
    {ast, put(acc, as, parts, ns)}
  end

  # alias Tars.LLM
  defp collect({:alias, _, [{:__aliases__, _, parts}]} = ast, acc, ns) do
    {ast, put(acc, List.last(parts), parts, ns)}
  end

  # alias Tars.{Event, LLM.Config}
  defp collect(
         {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, groups}]} = ast,
         acc,
         ns
       ) do
    acc =
      Enum.reduce(groups, acc, fn
        {:__aliases__, _, parts}, acc -> put(acc, List.last(parts), prefix ++ parts, ns)
        _other, acc -> acc
      end)

    {ast, acc}
  end

  defp collect(ast, acc, _ns), do: {ast, acc}

  defp put(acc, name, parts, namespaces) when is_atom(name) do
    if Enum.all?(parts, &is_atom/1) and to_string(hd(parts)) in namespaces do
      Map.put(acc, name, parts)
    else
      acc
    end
  end

  defp put(acc, _name, _parts, _namespaces), do: acc

  # A typespec names a type, not a call, and the call graph does not read it.
  @typespecs [:spec, :type, :typep, :opaque, :callback, :macrocallback]

  defp walk({:@, _, [{attribute, _, _}]}, ctx, _aliases) when attribute in @typespecs do
    {nil, ctx}
  end

  # Alias.Sub.fun(...) where Alias is a collected alias
  defp walk({{:., _, [{:__aliases__, meta, [first | rest]}, fun]}, _, _} = ast, ctx, aliases)
       when rest != [] and is_atom(fun) do
    case Map.fetch(aliases, first) do
      {:ok, parts} -> {ast, Context.put_issue(ctx, issue_for(ctx, meta, first, rest, fun, parts))}
      :error -> {ast, ctx}
    end
  end

  defp walk(ast, ctx, _aliases), do: {ast, ctx}

  defp issue_for(issue_meta, meta, first, rest, fun, parts) do
    written = Enum.join([first | rest], ".")
    full = Enum.join(parts ++ rest, ".")

    format_issue(
      issue_meta,
      message: "Call #{full}.#{fun} as itself, or alias #{full}, rather than through #{first}.",
      trigger: "#{written}.#{fun}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
