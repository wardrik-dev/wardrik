defmodule Wardrik.History do
  @moduledoc """
  What an agent keeps of its history: a seam that may rewrite the history
  before each turn begins.

  A turn's task hands the agent's history to its config's `:history` first,
  before the messages the turn answers join it, so those stay word for word.
  The agent keeps what it answers: the turn runs on it, a turn that parks or
  is lost keeps it, and `Wardrik.Event.ContextCompacted` reports what changed on
  the turn's trace. `Wardrik.Compaction`, the default, summarises the older
  part once the history outgrows what the model can read.

      Wardrik.LLM.Config.new(history: {MyApp.Retention, days: 30})

  A history is named as a module, or a module and the value it reads,
  `{module, value}`, so it travels with the agent as data. `nil` keeps every
  message.

  `c:prepare/3` answers the history to keep, `:keep` to keep it as it is, or
  `{:error, reason}`, which keeps it as it is too, and is logged. One that
  raises or answers anything else is taken the same way, so a broken history
  leaves the agent its turns rather than failing every one of them.

  It runs in the turn's task: a model call it makes is one of the turn's,
  decided and counted by its hooks (see `Wardrik.Call.Pipeline`), and
  interrupting the turn interrupts it. It runs before a fresh turn alone; a
  turn carried on from a checkpoint or a park runs on the history it had.
  """

  require Logger

  alias ReqLLM.Context
  alias Wardrik.LLM.Tokens
  alias Wardrik.Run

  @typedoc "A history as a config names it: a module, a module and its value, or `nil`."
  @type t() :: module() | {module(), term()} | nil

  @typedoc "What a rewrite did, as `Wardrik.Event.ContextCompacted` reports it."
  @type stats() :: %{
          messages_before: non_neg_integer(),
          messages_after: non_neg_integer(),
          tokens_before: non_neg_integer(),
          tokens_after: non_neg_integer()
        }

  @doc """
  The history to keep in place of `history` before a turn under `run`,
  `:keep` for the history as it is, or `{:error, reason}`, which keeps it too.
  `value` is what the config named the module with, or `nil`.
  """
  @callback prepare(history :: Context.t(), Run.t(), value :: term()) ::
              {:ok, Context.t()} | :keep | {:error, term()}

  @doc """
  What `seam` keeps of `history` before a turn under `run`: the history it
  rewrote, with what changed, or `:keep`.
  """
  @spec prepare(t(), Context.t(), Run.t()) :: {:ok, Context.t(), stats()} | :keep
  def prepare(nil, %Context{}, %Run{}), do: :keep

  def prepare(module, %Context{} = history, %Run{} = run) when is_atom(module),
    do: prepare({module, nil}, history, run)

  def prepare({module, value}, %Context{} = history, %Run{} = run) do
    case module.prepare(history, run, value) do
      {:ok, %Context{} = kept} -> {:ok, kept, stats(history, kept)}
      :keep -> :keep
      {:error, reason} -> kept(module, reason)
      other -> kept(module, {:invalid_answer, other})
    end
  catch
    kind, reason -> kept(module, Exception.format(kind, reason))
  end

  defp kept(module, reason) do
    Logger.warning("#{inspect(module)} kept the history as it was: #{inspect(reason)}")
    :keep
  end

  defp stats(before, kept) do
    before = Context.to_list(before)
    kept = Context.to_list(kept)

    %{
      messages_before: length(before),
      messages_after: length(kept),
      tokens_before: Tokens.messages(before),
      tokens_after: Tokens.messages(kept)
    }
  end
end
