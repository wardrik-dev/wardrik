defmodule Wardrik.Credo.Check.VerbFunctionNames do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      A function is named for what it does, as a verb: `build_request`, `validate_input`,
      `encode_result`. A name in the past tense says what happened, not what the function does.

          # what it returns, or what happened?
          defp described(operation), do: ...
          defp ran(operations, id, input), do: ...

          # what it does
          defp build_description(operation), do: ...
          defp perform(operations, id, input), do: ...

      A predicate, whose name ends in `?`, may be an adjective or a participle, as Elixir's own
      are: `allowed?`, `Process.alive?`, `Code.ensure_loaded?`.
      """
    ]

  @defs [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard, :defguardp]

  # Words ending in -ed that aren't past tenses.
  @not_past ~w(need feed seed speed embed proceed succeed exceed bleed breed shed weed heed bed
               red shred wed sled hundred kindred)

  @irregular ~w(ran sent kept made done found given held built left lost paid said seen shown
                taken told thought written got gotten known chosen begun broken bound drawn fed
                led met sold spent stood struck won hidden forgotten frozen grown laid lent meant
                heard caught brought bought taught sought felt dealt slept swept stuck spun hung
                dug woken worn torn sworn thrown flown blown understood undone unsent unseen
                unknown)

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    Credo.Code.prewalk(source_file, &walk/2, ctx).issues
  end

  defp walk({def, meta, [head | _rest]} = ast, ctx) when def in @defs,
    do: {ast, check_name(ctx, meta, function_name(head))}

  defp walk(ast, ctx), do: {ast, ctx}

  defp function_name({:when, _meta, [head | _guards]}), do: function_name(head)
  defp function_name({name, _meta, _args}) when is_atom(name), do: Atom.to_string(name)
  defp function_name(_head), do: nil

  defp check_name(ctx, _meta, nil), do: ctx

  defp check_name(ctx, meta, name) do
    if past_tense?(name),
      do: Context.put_issue(ctx, issue_for(ctx, meta, name)),
      else: ctx
  end

  @doc false
  @spec past_tense?(String.t()) :: boolean()
  def past_tense?(name) do
    first =
      name
      |> String.trim_leading("_")
      |> String.split("_")
      |> hd()

    not String.ends_with?(name, "?") and first not in @not_past and
      (first in @irregular or (String.length(first) > 3 and String.ends_with?(first, "ed")))
  end

  defp issue_for(ctx, meta, name) do
    format_issue(
      ctx,
      message: "Name #{name} for what it does, as a verb, not in the past tense.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
