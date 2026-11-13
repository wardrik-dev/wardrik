defmodule WardrikWeb.Operations do
  @moduledoc false

  # Webhooks and chat apps call the operations with these subjects.
  @inbound ~w(hook channel)

  @doc "Whether the operation is called by webhooks or chat apps rather than by people."
  @spec inbound?(WardrikProtocol.operation()) :: boolean()
  def inbound?(%{subject: subject}), do: subject in @inbound
end
