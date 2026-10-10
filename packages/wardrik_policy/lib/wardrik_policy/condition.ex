defmodule WardrikPolicy.Condition do
  @moduledoc """
  What a rule says a call's arguments hold, in parentheses after the tool:
  `books/create_bill(amount > 500)`, `books/*(account: Payroll)`, and
  several, comma-separated, that must all hold:
  `books/create_bill(amount >= 1000, vendor.name: Acme*)`.

  An argument is named by its key, or by keys joined with dots into nested
  ones, `vendor.name`. Through a list, the path names each item's:
  `lines.amount` is the amount of each of `lines`.

    * `name: value` holds where the argument is the value, ignoring case,
      with `*` for any run of characters. A value in double quotes may hold
      commas, and spaces at its ends. An unquoted number, `amount: 500`,
      compares as a number with a number.
    * `name != value` holds where `name: value` does not, as `to != *@acme.com`
      for an address outside, or `amount != 0`.
    * `name > number`, `>=`, `<` and `<=` hold where the argument is a number
      that compares so.

  Text that reads whole as a number, `"600"` or `" 600.5 "`, counts as one.

  ## What a call cannot be checked against

  A condition holds `true`, `false` or `:maybe` for a call:

    * `false` where the call leaves the argument out, or gives it as null
    * `:maybe` where it gives the argument in a form the condition cannot be
      checked against: text that is no number, or `true`, compared with a
      number; an object where a value is named; a value where an object's
      key is named
    * for a list, `true` where every item holds, `false` where none does,
      and `:maybe` otherwise; an empty list holds `false`

  Several conditions hold `false` where one does, `true` where all do, and
  `:maybe` otherwise. A rule that asks or denies speaks for a call its
  conditions may hold for, and one that allows only for a call they surely
  hold for (see `WardrikPolicy.Rule`).

  Conditions are parsed once, into plain data, and a call is checked
  against them without a regular expression.
  """

  alias WardrikPolicy.Pattern

  @enforce_keys [:path, :test]
  defstruct [:path, :test]

  @typedoc "`{:is, glob, number}` for `name: value`, the number where the value is one."
  @type test() ::
          {:is | :is_not, [String.t()], number() | nil}
          | {:gt | :ge | :lt | :le, number()}

  @type t() :: %__MODULE__{path: [String.t()], test: test()}

  @typedoc "Whether conditions hold for a call."
  @type held() :: boolean() | :maybe

  @condition ~r/\A([A-Za-z_][\w-]*(?:\.[\w-]+)*)\s*(>=|<=|!=|>|<|:(?=\s|"|\z))\s*(.*)\z/su
  @comparisons %{">" => :gt, ">=" => :ge, "<" => :lt, "<=" => :le}
  @syntax "conditions go as name: value, name != value or name > number, comma-separated, as " <>
            "books/create_bill(amount > 500, account: Payroll)"

  @doc """
  The conditions `text`, what is in a pattern's parentheses, writes;
  `:subject` where it writes what a call acts on instead, as `notes/*`.
  An error says why, to follow the pattern it is in.
  """
  @spec parse(String.t()) :: {:ok, [t()]} | :subject | {:error, String.t()}
  def parse(text) do
    read =
      Enum.map(pieces(text), &Regex.run(@condition, String.trim(&1), capture: :all_but_first))

    case Enum.split_with(read, &is_nil/1) do
      {_subjects, []} ->
        :subject

      {[], conditions} ->
        conditions
        |> Enum.map(fn [path, operator, value] -> condition(path, operator, value) end)
        |> collected()

      _mixed ->
        {:error,
         "puts conditions beside what a call acts on; the parentheses hold one or the other: " <>
           "what a call acts on, as write_file(notes/*), or #{@syntax}"}
    end
  end

  defp collected(conditions) do
    case Enum.find(conditions, &match?({:error, _message}, &1)) do
      nil -> {:ok, Enum.map(conditions, fn {:ok, condition} -> condition end)}
      error -> error
    end
  end

  defp condition(path, operator, value) when operator in [":", "!="] do
    with {:ok, text} <- value(path, value) do
      quoted? = String.starts_with?(value, "\"")
      number = if quoted?, do: nil, else: number(text)
      is = if operator == ":", do: :is, else: :is_not
      test = {is, text |> String.downcase() |> String.split("*"), number}
      {:ok, %__MODULE__{path: String.split(path, "."), test: test}}
    end
  end

  defp condition(path, operator, value) do
    case number(value) do
      nil ->
        {:error,
         "compares #{path} with #{inspect(value)}, which is not a number; " <>
           ">, >=, < and <= take one, as amount > 500"}

      number ->
        {:ok, %__MODULE__{path: String.split(path, "."), test: {@comparisons[operator], number}}}
    end
  end

  defp value(path, "\"" <> rest = value) do
    case String.split(rest, "\"") do
      [text, ""] -> {:ok, text}
      _other -> {:error, "gives #{path} #{value}, which is not one value in double quotes"}
    end
  end

  defp value(path, ""),
    do: {:error, "gives #{path} no value; #{@syntax}"}

  defp value(path, value) do
    if String.contains?(value, "\""),
      do: {:error, "gives #{path} #{value}; a value in double quotes is quoted whole"},
      else: {:ok, value}
  end

  # The comma-separated pieces of `text`, apart from commas in double quotes.
  defp pieces(text), do: pieces(text, "", false, [])

  defp pieces(<<>>, piece, _quoted?, pieces), do: Enum.reverse([piece | pieces])

  defp pieces(<<?,, rest::binary>>, piece, false, pieces),
    do: pieces(rest, "", false, [piece | pieces])

  defp pieces(<<?", rest::binary>>, piece, quoted?, pieces),
    do: pieces(rest, piece <> "\"", not quoted?, pieces)

  defp pieces(<<byte, rest::binary>>, piece, quoted?, pieces),
    do: pieces(rest, <<piece::binary, byte>>, quoted?, pieces)

  defp number(text) do
    text = String.trim(text)

    case Integer.parse(text) do
      {integer, ""} ->
        integer

      _other ->
        case Float.parse(text) do
          {float, ""} -> float
          _other -> nil
        end
    end
  end

  @doc "Whether `conditions` hold for a call with `arguments`."
  @spec held([t()], map()) :: held()
  def held(conditions, arguments) do
    Enum.reduce_while(conditions, true, fn condition, held ->
      case check(arguments, condition.path, condition.test) do
        false -> {:halt, false}
        true -> {:cont, held}
        :maybe -> {:cont, :maybe}
      end
    end)
  end

  defp check(nil, _path, _test), do: false

  defp check(items, path, test) when is_list(items),
    do: each(Enum.map(items, &check(&1, path, test)))

  defp check(%{} = object, [key | path], test), do: check(Map.get(object, key), path, test)
  defp check(%{}, [], _test), do: :maybe
  defp check(_value, [_key | _path], _test), do: :maybe
  defp check(value, [], test), do: test(test, value)

  defp each([]), do: false

  defp each(held) do
    cond do
      Enum.all?(held, &(&1 == true)) -> true
      Enum.all?(held, &(&1 == false)) -> false
      true -> :maybe
    end
  end

  defp test({:is_not, glob, number}, value)
       when is_binary(value) or is_number(value) or is_boolean(value),
       do: not test({:is, glob, number}, value)

  defp test({:is, _glob, number}, value) when is_number(value) and is_number(number),
    do: value == number

  defp test({:is, glob, number}, value) when is_binary(value) do
    case is_number(number) && number(value) do
      read when is_number(read) -> read == number
      _text -> Pattern.glob?(glob, String.downcase(value))
    end
  end

  defp test({:is, glob, _number}, value) when is_number(value) or is_boolean(value),
    do: Pattern.glob?(glob, to_string(value))

  defp test({comparison, number}, value) when is_number(value),
    do: compare(comparison, value, number)

  defp test({comparison, number}, value) when is_binary(value) do
    case number(value) do
      nil -> :maybe
      read -> compare(comparison, read, number)
    end
  end

  defp test(_test, _value), do: :maybe

  defp compare(:gt, value, number), do: value > number
  defp compare(:ge, value, number), do: value >= number
  defp compare(:lt, value, number), do: value < number
  defp compare(:le, value, number), do: value <= number
end
