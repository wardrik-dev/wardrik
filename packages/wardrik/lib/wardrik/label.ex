defmodule Wardrik.Label do
  @moduledoc """
  What a run has read, named: a string a tool, a delegate or a message gives
  the run, which it carries from then on, as the agent's history does after
  it until the history is cleared.

  Core carries labels and decides nothing from them. A `Wardrik.Hook` reads
  the labels of the run a call belongs to from its scope (`Wardrik.Scope`'s
  `:labels`) and decides what they mean; `WardrikPolicy` holds a gated
  tool's calls for a person after some of them.

  `"outside"` is content nobody on the agent's side wrote, such as a web
  page, an issue, or a message from a stranger: what the run read may be what
  asks for its next call. A tool that answers with it says so in its
  annotations, or in one answer; see `Wardrik.Tool.Annotations`.
  """

  @typedoc "A label: `\"outside\"`, or any name a tool and a policy agree on."
  @type t() :: String.t()

  @doc "`labels` and `more` together, each once, in order."
  @spec union([t()], [t()]) :: [t()]
  def union(labels, more) when is_list(labels) and is_list(more),
    do: (labels ++ more) |> Enum.uniq() |> Enum.sort()

  @doc """
  What content with `labels` is, as a person reads it: `"content from
  outside"`, `"content labelled books"`, or both, joined with `and`.
  """
  @spec described([t()]) :: String.t()
  def described(labels) when is_list(labels), do: Enum.map_join(labels, " and ", &content/1)

  defp content("outside"), do: "content from outside"
  defp content(label), do: ["content labelled ", label]
end
