defmodule Wardrik.Resolver.Request do
  @moduledoc """
  What `c:Wardrik.Resolver.resolve/2` resolves: the agent `agent`, defined as `definition`.

      %Wardrik.Resolver.Request{agent: "agt_01JF8", definition: %{"model" => "anthropic:claude-haiku-4-5"}}

  `definition` is `%{}` for an agent started without one.
  """

  @enforce_keys [:agent]
  defstruct [:agent, definition: %{}]

  @type t() :: %__MODULE__{agent: String.t(), definition: map()}
end
