defmodule WardrikChannel.Approvers.Named do
  @moduledoc """
  The people a channel's `approvers` name, each as the channel names people,
  such as by handle or email address; none where it names nobody. See
  `WardrikChannel.Approvers`.
  """

  @enforce_keys [:names]
  defstruct [:names]

  @type t() :: %__MODULE__{names: [String.t()]}

  defimpl WardrikChannel.Approvers do
    def decides?(%{names: names}, include?), do: include?.(names)

    def asked(%{names: names}), do: names

    def described(%{names: []}),
      do: "names no approvers: whoever asks decides their own turn, and a shell the rest"

    def described(%{names: [name]}), do: name <> " decides"
    def described(%{names: names}), do: "#{Enum.join(names, ", ")} decide"
  end
end
