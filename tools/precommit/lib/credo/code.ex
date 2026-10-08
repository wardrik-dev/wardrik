defmodule Wardrik.Credo.Code do
  @moduledoc """
  What the project checks share: the modules a file's `alias` lines name, and
  the module and function a remote call reaches through them.
  """

  @typedoc "Each alias a file declares, by the name it is called by."
  @type aliases() :: %{atom() => [atom()]}

  @doc "The aliases `ast` declares anywhere in it."
  @spec aliases(Macro.t()) :: aliases()
  def aliases(ast) do
    {_ast, aliases} = Macro.prewalk(ast, %{}, &collect/2)
    aliases
  end

  @doc """
  The module a remote call reaches, as written in source (`"Task"`,
  `"WardrikStore"`, `":inet"`), with its function and where it is; or
  `:error` for anything else.
  """
  @spec remote(Macro.t(), aliases()) :: {:ok, String.t(), atom(), keyword()} | :error
  def remote({{:., meta, [{:__aliases__, _, parts}, fun]}, _, args}, aliases)
      when is_atom(fun) and is_list(args) do
    if Enum.all?(parts, &is_atom/1),
      do: {:ok, name(parts, aliases), fun, meta},
      else: :error
  end

  def remote({{:., meta, [module, fun]}, _, args}, _aliases)
      when is_atom(module) and is_atom(fun) and is_list(args),
      do: {:ok, inspect(module), fun, meta}

  def remote(_ast, _aliases), do: :error

  @doc "The full name of a module written as `parts`, through `aliases`."
  @spec name([atom()], aliases()) :: String.t()
  def name([first | rest] = parts, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, full} -> Enum.join(full ++ rest, ".")
      :error -> Enum.join(parts, ".")
    end
  end

  @doc """
  The definition `ast` with its head taken out, so a walk goes through its
  body alone; anything else as it is.
  """
  @spec bodies_only(Macro.t()) :: Macro.t()
  def bodies_only({op, meta, [_head | rest]}) when op in [:def, :defp],
    do: {op, meta, [:head | rest]}

  def bodies_only({:@, meta, [{name, _, _}]}) when name in [:spec, :callback, :type, :typep],
    do: {:@, meta, []}

  def bodies_only(ast), do: ast

  @doc """
  Each `def` and `defp` in `ast` as `{name, arity}`, so a bare call to a
  function of the file's own is told apart from Kernel's of the same name.
  """
  @spec defined(Macro.t()) :: MapSet.t({atom(), non_neg_integer()})
  def defined(ast) do
    {_ast, defined} =
      Macro.prewalk(ast, MapSet.new(), fn
        {op, _, [head | _]} = node, acc when op in [:def, :defp] ->
          case unguarded(head) do
            {name, _, args} when is_atom(name) and is_list(args) ->
              {node, MapSet.put(acc, {name, length(args)})}

            {name, _, context} when is_atom(name) and is_atom(context) ->
              {node, MapSet.put(acc, {name, 0})}

            _other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    defined
  end

  defp unguarded({:when, _, [head, _guard]}), do: head
  defp unguarded(head), do: head

  defp collect({:alias, _, [{:__aliases__, _, parts}]} = ast, acc),
    do: {ast, put(acc, parts, List.last(parts))}

  defp collect({:alias, _, [{:__aliases__, _, parts}, opts]} = ast, acc) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, [as]} -> {ast, put(acc, parts, as)}
      _none -> {ast, put(acc, parts, List.last(parts))}
    end
  end

  defp collect({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = ast, acc) do
    acc =
      Enum.reduce(children, acc, fn
        {:__aliases__, _, parts}, acc -> put(acc, base ++ parts, List.last(parts))
        _other, acc -> acc
      end)

    {ast, acc}
  end

  defp collect(ast, acc), do: {ast, acc}

  defp put(acc, parts, as) do
    if Enum.all?(parts, &is_atom/1), do: Map.put(acc, as, parts), else: acc
  end
end
