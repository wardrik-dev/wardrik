defmodule WardrikDaemon.Pairings do
  @moduledoc """
  Pairs a browser sign-in with the `wardrik` command that started it (RFC 8628 §6.1).

  The callback page can't tell who is at the browser, so it connects nothing. It shows a code.
  The person types it where they ran `wardrik connection connect`, or runs:

      wardrik connection pair linear BCDF-GHJK

    * A code is 8 letters, shown as `BCDF-GHJK`. Case and the dash are ignored.
    * It works once, for 10 minutes, and only for the person who started the sign-in.
    * After 5 wrong codes, the sign-in ends.
    * Codes live in this process only, never in a URL or a log.
  """

  use GenServer

  alias WardrikCore.Principal

  @alphabet "BCDFGHJKLMNPQRSTVWXZ"
  @length 8
  @runs div(256, byte_size(@alphabet)) * byte_size(@alphabet)
  @lifetime :timer.minutes(10)
  @attempts 5
  @started_for :timer.minutes(15)

  @typedoc "A sign-in a principal started, by the provider's name and the credential it fills."
  @type sign_in() :: %{principal: Principal.t(), provider: String.t(), credential: String.t()}

  @doc "Starts it, registered as `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.fetch!(opts, :name))

  @doc "Returns the name it runs under for the Wardrik `wardrik`."
  @spec name(atom()) :: atom()
  def name(wardrik), do: Module.concat(wardrik, Pairings)

  @doc """
  Notes a browser sign-in by its `state`. Replaces the person's earlier sign-in to the same credential.
  """
  @spec started(GenServer.server(), String.t(), sign_in()) :: :ok
  def started(pairings, state, %{principal: %Principal{}} = sign_in),
    do: GenServer.call(pairings, {:started, state, sign_in})

  @doc """
  Takes a callback's params. Returns the code to show and its sign-in, `{:declined, sign_in}`, or `:error`.
  """
  @spec called_back(GenServer.server(), map()) ::
          {:ok, String.t(), sign_in()} | {:declined, sign_in()} | :error
  def called_back(pairings, params), do: GenServer.call(pairings, {:called_back, params})

  @doc """
  Pairs `code` with `principal`'s sign-in to `credential`. Returns the callback's params, once.

  Returns `{:error, :mismatch}` for a wrong code, and `{:error, {:ended, sign_in, state}}` once
  it's ended or expired.
  """
  @spec pair(GenServer.server(), {Principal.t(), String.t()}, String.t()) ::
          {:ok, map()} | {:error, :mismatch | {:ended, sign_in(), String.t()}}
  def pair(pairings, {%Principal{} = principal, credential}, code),
    do: GenServer.call(pairings, {:pair, {principal.id, credential}, normal(code)})

  @doc "Returns `code` as it's shown, as `BCDF-GHJK`."
  @spec shown(String.t()) :: String.t()
  def shown(<<first::binary-size(4), last::binary-size(4)>>), do: first <> "-" <> last

  @impl GenServer
  def init(nil), do: {:ok, %{}}

  @impl GenServer
  # The same sign-in, asked for again, keeps any code its page showed.
  def handle_call({:started, state, _sign_in}, _from, sign_ins)
      when is_map_key(sign_ins, state),
      do: {:reply, :ok, sign_ins}

  def handle_call({:started, state, sign_in}, _from, sign_ins) do
    key = key(sign_in)

    sign_ins =
      sign_ins
      |> Map.reject(fn {_state, held} -> key(held) == key end)
      |> live()

    held = Map.merge(sign_in, %{code: nil, attempts: 0, until: now() + @started_for})
    {:reply, :ok, Map.put(sign_ins, state, held)}
  end

  def handle_call({:called_back, params}, _from, sign_ins) do
    sign_ins = live(sign_ins)

    case params do
      %{"state" => state, "code" => _code} when is_map_key(sign_ins, state) ->
        code = code()
        held = %{sign_ins[state] | code: code, until: now() + @lifetime}
        sign_ins = %{sign_ins | state => Map.put(held, :params, params)}
        {:reply, {:ok, shown(code), sign_in(held)}, sign_ins}

      %{"state" => state} when is_map_key(sign_ins, state) ->
        {held, sign_ins} = Map.pop!(sign_ins, state)
        {:reply, {:declined, sign_in(held)}, sign_ins}

      _unknown ->
        {:reply, :error, sign_ins}
    end
  end

  def handle_call({:pair, key, code}, _from, sign_ins) do
    {ended, sign_ins} = Map.split_with(sign_ins, fn {_state, held} -> expired?(held) end)
    waiting = Enum.find(sign_ins, fn {_state, held} -> key(held) == key and held.code != nil end)
    expired = Enum.find(ended, fn {_state, held} -> key(held) == key end)

    case {waiting, expired} do
      {{state, held}, _expired} -> paired(state, held, code, sign_ins)
      {nil, {state, held}} -> {:reply, {:error, {:ended, sign_in(held), state}}, sign_ins}
      {nil, nil} -> {:reply, {:error, :mismatch}, sign_ins}
    end
  end

  defp paired(state, held, code, sign_ins) do
    attempts = held.attempts + 1

    cond do
      byte_size(code) == @length and Plug.Crypto.secure_compare(code, held.code) ->
        {:reply, {:ok, held.params}, Map.delete(sign_ins, state)}

      attempts >= @attempts ->
        {:reply, {:error, {:ended, sign_in(held), state}}, Map.delete(sign_ins, state)}

      true ->
        {:reply, {:error, :mismatch}, %{sign_ins | state => %{held | attempts: attempts}}}
    end
  end

  defp live(sign_ins), do: Map.reject(sign_ins, fn {_state, held} -> expired?(held) end)

  defp expired?(held), do: held.until <= now()

  defp key(%{principal: %Principal{id: id}, credential: credential}), do: {id, credential}

  defp sign_in(held), do: Map.take(held, [:principal, :provider, :credential])

  defp normal(code) do
    code
    |> String.replace("-", "")
    |> String.trim()
    |> String.upcase()
  end

  # Each letter is drawn evenly: bytes past the last whole run of the alphabet are drawn again.
  defp code, do: code([])

  defp code(letters) when length(letters) == @length, do: IO.iodata_to_binary(letters)

  defp code(letters) do
    <<byte>> = :crypto.strong_rand_bytes(1)

    if byte < @runs,
      do: code([binary_part(@alphabet, rem(byte, byte_size(@alphabet)), 1) | letters]),
      else: code(letters)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
