defmodule Wardrik.Store.Durable.Unreadable do
  @moduledoc """
  Says why a saved state can't be read: the modules and atoms it names that this release
  doesn't have.

      Wardrik.Store.Durable.Unreadable.reason(:erlang.term_to_binary(%{policy: SomeGoneModule}))
      #=> "it names SomeGoneModule, which this release doesn't have"

  It reads the term's encoding without decoding it, so no atom is ever created.
  """

  @shown 5

  @doc "Returns why `binary`, an encoded Erlang term, can't be read safely."
  @spec reason(binary()) :: String.t()
  def reason(binary) do
    case atoms(binary) do
      {:ok, atoms} -> atoms |> missing() |> named()
      :error -> "it isn't in a form this release can read"
    end
  end

  @doc """
  Loads the modules `binary` names that aren't loaded yet but are on the code path, as in
  development, where modules load when first called. Returns whether it loaded any.
  """
  @spec load_named(binary()) :: boolean()
  def load_named(binary) do
    case atoms(binary) do
      {:ok, atoms} ->
        for(text <- Enum.uniq(atoms), not exists?(text), path <- beam(text), do: load(path))
        |> Enum.any?()

      :error ->
        false
    end
  end

  # Modules first: a module this release doesn't have is the likeliest reason.
  defp missing(atoms) do
    gone = atoms |> Enum.uniq() |> Enum.reject(&exists?/1)
    modules = Enum.filter(gone, &String.starts_with?(&1, "Elixir."))
    if modules == [], do: gone, else: modules
  end

  defp beam(text) do
    case :code.where_is_file(String.to_charlist(text <> ".beam")) do
      :non_existing -> []
      path -> [path]
    end
  end

  defp load(path),
    do:
      match?(
        {:module, _module},
        path |> Path.rootname() |> String.to_charlist() |> :code.load_abs()
      )

  @doc "Returns every atom `binary` names, as text, or `:error` if it isn't an encoded term."
  @spec atoms(binary()) :: {:ok, [String.t()]} | :error
  def atoms(<<131, 80, _size::32, compressed::binary>>),
    do: atoms(<<131>> <> :zlib.uncompress(compressed))

  def atoms(<<131, rest::binary>>) do
    case terms(rest, 1, []) do
      {:ok, _rest, atoms} -> {:ok, Enum.reverse(atoms)}
      :error -> :error
    end
  end

  def atoms(_binary), do: :error

  defp named([]), do: "it isn't in a form this release can read"

  defp named(missing) do
    {shown, more} = missing |> Enum.map(&readable/1) |> Enum.split(@shown)
    listed = if more == [], do: sentence(shown), else: sentence(shown ++ ["#{length(more)} more"])
    "it names #{listed}, which this release doesn't have"
  end

  defp readable("Elixir." <> module), do: module
  defp readable(atom), do: ":" <> atom

  defp sentence([one]), do: one

  defp sentence(many) do
    {rest, [last]} = Enum.split(many, -1)
    IO.iodata_to_binary([Enum.intersperse(rest, ", "), " and ", last])
  end

  # The only way to ask whether an atom exists without creating it.
  defp exists?(text) do
    _atom = String.to_existing_atom(text)
    true
  rescue
    ArgumentError -> false
  end

  defp terms(rest, 0, atoms), do: {:ok, rest, atoms}

  defp terms(<<tag, rest::binary>>, count, atoms) do
    case term(tag, rest, atoms) do
      {:ok, rest, atoms, inside} -> terms(rest, count - 1 + inside, atoms)
      :error -> :error
    end
  end

  defp terms(_rest, _count, _atoms), do: :error

  defp term(tag, <<length::16, name::binary-size(length), rest::binary>>, atoms)
       when tag in [100, 118],
       do: {:ok, rest, [text(tag, name) | atoms], 0}

  defp term(tag, <<length, name::binary-size(length), rest::binary>>, atoms)
       when tag in [115, 119],
       do: {:ok, rest, [text(tag, name) | atoms], 0}

  defp term(97, <<_integer, rest::binary>>, atoms), do: {:ok, rest, atoms, 0}
  defp term(98, <<_integer::32, rest::binary>>, atoms), do: {:ok, rest, atoms, 0}
  defp term(70, <<_float::64, rest::binary>>, atoms), do: {:ok, rest, atoms, 0}
  defp term(99, <<_float::binary-size(31), rest::binary>>, atoms), do: {:ok, rest, atoms, 0}
  defp term(106, rest, atoms), do: {:ok, rest, atoms, 0}
  defp term(104, <<arity, rest::binary>>, atoms), do: {:ok, rest, atoms, arity}
  defp term(105, <<arity::32, rest::binary>>, atoms), do: {:ok, rest, atoms, arity}
  defp term(116, <<arity::32, rest::binary>>, atoms), do: {:ok, rest, atoms, 2 * arity}
  defp term(108, <<length::32, rest::binary>>, atoms), do: {:ok, rest, atoms, length + 1}

  defp term(107, <<length::16, _chars::binary-size(length), rest::binary>>, atoms),
    do: {:ok, rest, atoms, 0}

  defp term(109, <<length::32, _bytes::binary-size(length), rest::binary>>, atoms),
    do: {:ok, rest, atoms, 0}

  defp term(77, <<length::32, _bits, _bytes::binary-size(length), rest::binary>>, atoms),
    do: {:ok, rest, atoms, 0}

  defp term(110, <<length, _sign, _digits::binary-size(length), rest::binary>>, atoms),
    do: {:ok, rest, atoms, 0}

  defp term(111, <<length::32, _sign, _digits::binary-size(length), rest::binary>>, atoms),
    do: {:ok, rest, atoms, 0}

  defp term(113, rest, atoms), do: {:ok, rest, atoms, 3}

  defp term(112, <<size::32, rest::binary>>, atoms) when size >= 4 do
    case rest do
      <<_fun::binary-size(^size - 4), rest::binary>> -> {:ok, rest, atoms, 0}
      _short -> :error
    end
  end

  defp term(88, rest, atoms), do: noded(rest, atoms, 12)
  defp term(89, rest, atoms), do: noded(rest, atoms, 8)
  defp term(120, rest, atoms), do: noded(rest, atoms, 12)

  defp term(90, <<length::16, rest::binary>>, atoms), do: noded(rest, atoms, 4 + 4 * length)

  defp term(_tag, _rest, _atoms), do: :error

  # Pids, ports and references name their node, then hold fixed-size numbers.
  defp noded(rest, atoms, size) do
    case terms(rest, 1, atoms) do
      {:ok, <<_numbers::binary-size(^size), rest::binary>>, atoms} -> {:ok, rest, atoms, 0}
      _short -> :error
    end
  end

  defp text(tag, name) when tag in [100, 115], do: :unicode.characters_to_binary(name, :latin1)
  defp text(_tag, name), do: name
end
