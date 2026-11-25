defmodule Wardrik.Chat.Prompts.Fixed do
  @moduledoc """
  Suggests the same prompts to every member: `:prompts`, a list of strings.

      slack: {WardrikSlack, ..., prompts: {Wardrik.Chat.Prompts.Fixed, prompts: ["Plan my week"]}}
  """

  @behaviour Wardrik.Chat.Prompts

  @impl Wardrik.Chat.Prompts
  def suggest(_request, opts), do: Keyword.fetch!(opts, :prompts)
end
