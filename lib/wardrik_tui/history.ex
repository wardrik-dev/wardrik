defmodule WardrikTUI.History do
  @moduledoc """
  Lines entered at the prompt, newest first, and a place in them.

  `push/2` records a line: a blank one is dropped, one equal to the newest is
  not repeated, and the oldest goes once there are more than `limit`. Pushing
  also leaves the list, as `leave/1` does.

  `back/2` steps to an older line, entering the list from `draft` with the
  newest, and `forward/1` steps to a newer one, past the newest back to the
  draft that was left. Either answers `:none` at its end. `browsing?/1` says
  whether a place in the list is held.
  """

  @limit 200

  defstruct entries: [], limit: @limit, at: nil, draft: nil

  @type t() :: %__MODULE__{
          entries: [String.t()],
          limit: pos_integer(),
          at: non_neg_integer() | nil,
          draft: String.t() | nil
        }

  @doc "An empty history keeping at most `limit` lines."
  @spec new(pos_integer()) :: t()
  def new(limit \\ @limit), do: %__MODULE__{limit: limit}

  @doc "Records `line` as the newest, and leaves the list."
  @spec push(t(), String.t()) :: t()
  def push(history, line) do
    history = leave(history)

    case String.trim(line) do
      "" -> history
      ^line when history.entries != [] and hd(history.entries) == line -> history
      _other -> %{history | entries: Enum.take([line | history.entries], history.limit)}
    end
  end

  @doc "The lines recorded, newest first."
  @spec entries(t()) :: [String.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "Whether a place in the list is held."
  @spec browsing?(t()) :: boolean()
  def browsing?(%__MODULE__{at: at}), do: at != nil

  @doc "Drops the place held and the draft kept with it."
  @spec leave(t()) :: t()
  def leave(history), do: %{history | at: nil, draft: nil}

  @doc """
  The next older line, keeping `draft` when this enters the list, or `:none`
  at the oldest.
  """
  @spec back(t(), String.t()) :: {String.t(), t()} | :none
  def back(%__MODULE__{entries: []}, _draft), do: :none

  def back(%__MODULE__{at: nil} = history, draft),
    do: {hd(history.entries), %{history | at: 0, draft: draft}}

  def back(%__MODULE__{at: at, entries: entries} = history, _draft)
      when at + 1 < length(entries),
      do: {Enum.at(entries, at + 1), %{history | at: at + 1}}

  def back(_history, _draft), do: :none

  @doc """
  The next newer line, or past the newest the draft kept on entering, or
  `:none` when no place is held.
  """
  @spec forward(t()) :: {String.t(), t()} | :none
  def forward(%__MODULE__{at: nil}), do: :none
  def forward(%__MODULE__{at: 0, draft: draft} = history), do: {draft || "", leave(history)}

  def forward(%__MODULE__{at: at} = history),
    do: {Enum.at(history.entries, at - 1), %{history | at: at - 1}}
end
