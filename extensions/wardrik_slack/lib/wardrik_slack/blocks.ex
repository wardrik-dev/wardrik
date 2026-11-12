defmodule WardrikSlack.Blocks do
  @moduledoc "Builds the Block Kit blocks of Wardrik's Slack messages."

  @max_markdown 12_000

  @doc "Returns a section of `mrkdwn` text."
  @spec section(String.t()) :: map()
  def section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}

  @doc "Returns a line of small `mrkdwn` text."
  @spec context(String.t()) :: map()
  def context(text), do: %{type: "context", elements: [%{type: "mrkdwn", text: text}]}

  @doc "Returns a `markdown` block, clipped to Slack's limit. Models write this kind of Markdown."
  @spec markdown(String.t()) :: map()
  def markdown(text), do: %{type: "markdown", text: clip(text, @max_markdown)}

  @doc "Returns an `actions` block of `elements`, such as buttons."
  @spec actions(String.t(), [map()]) :: map()
  def actions(block_id, elements), do: %{type: "actions", block_id: block_id, elements: elements}

  @doc ~S"""
  Returns a button labelled `label` that sends `:value` under `:action_id`.

      Blocks.button("Approve", action_id: "wardrik_approve", value: value, style: "primary")

  `:style` is `"primary"` or `"danger"`. None unless set.
  """
  @spec button(String.t(), keyword()) :: map()
  def button(label, args) do
    button = %{
      type: "button",
      text: plain(label),
      action_id: Keyword.fetch!(args, :action_id),
      value: Keyword.fetch!(args, :value)
    }

    case Keyword.get(args, :style) do
      nil -> button
      style -> Map.put(button, :style, style)
    end
  end

  @doc "Returns a `plain_text` object, as buttons and options take."
  @spec plain(String.t()) :: map()
  def plain(text), do: %{type: "plain_text", text: text}

  @doc "Returns a reply to a button press that only the person who pressed sees."
  @spec ephemeral(String.t()) :: map()
  def ephemeral(text), do: %{response_type: "ephemeral", replace_original: false, text: text}

  @doc "Returns `text` cut to `max` characters. Cut text ends in `…`."
  @spec clip(String.t(), pos_integer()) :: String.t()
  def clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
