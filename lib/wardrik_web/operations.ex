defmodule WardrikWeb.Operations do
  @moduledoc false

  # Webhooks and chat apps reach Wardrik through these subjects; people run the rest.
  @inbound ~w(hook channel)

  @doc "Whether other systems, not people, call the operation."
  def inbound?(%{subject: subject}), do: subject in @inbound
end
