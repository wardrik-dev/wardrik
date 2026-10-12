defmodule Wardrik.Operations.Reloading do
  @moduledoc "The effect of reloading the deployment's definitions: the nodes that read them again."

  @enforce_keys [:nodes]
  defstruct [:nodes]

  @type t() :: %__MODULE__{nodes: [node()]}

  defimpl Wardrik.Effect do
    def preview(%{nodes: nodes}),
      do: %{"reloading" => %{"nodes" => Enum.map(nodes, &to_string/1)}}

    def audit(%{nodes: nodes}), do: [{:agents_reloaded, nodes}]
  end
end
