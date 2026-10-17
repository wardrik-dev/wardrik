defmodule WardrikChannel.Member do
  @moduledoc """
  Someone in a workspace a channel is installed in: the
  `WardrikChannel.Installation` of the workspace, and the id the channel
  knows them by there, such as a Slack member id. `WardrikChannel.principal/2`
  is who they are to Wardrik, and `WardrikChannel.include?/3` whether names
  a config gives name them.
  """

  alias WardrikChannel.Installation

  @enforce_keys [:installation, :id]
  defstruct [:installation, :id]

  @type t() :: %__MODULE__{installation: Installation.t(), id: String.t()}

  @doc "The member `id` of the workspace of `installation`."
  @spec new(Installation.t(), String.t()) :: t()
  def new(%Installation{} = installation, id) when is_binary(id),
    do: %__MODULE__{installation: installation, id: id}
end
