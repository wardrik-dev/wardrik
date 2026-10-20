defmodule WardrikChannel.Installations.Config do
  @moduledoc """
  The installations a deployment's config names: one per channel that
  names a token, in the one workspace that token reaches, which is named as
  the channel is, since the config does not say which it is. `fetch/3`
  answers a channel's for every workspace the medium names, since its
  token reaches one only, and `owned/3` answers it for the owner it was
  installed for; installing more is refused, and deleting one leaves the
  config as it is.
  """

  alias WardrikChannel.Installation

  @enforce_keys [:installations]
  defstruct [:installations]

  @type t() :: %__MODULE__{installations: %{String.t() => Installation.t()}}

  @doc """
  Returns the installations of the channels `tokens` names: each with its
  token, the owner it is for, and the channel's approvers.
  """
  @spec new([
          {atom() | String.t(), String.t(), Wardrik.Resource.t(), WardrikChannel.Approvers.t()}
        ]) :: t()
  def new(tokens) do
    installations =
      for {channel, token, owner, approvers} <- tokens, into: %{} do
        channel = to_string(channel)

        {channel,
         %Installation{
           channel: channel,
           workspace: channel,
           owner: owner,
           token: token,
           approvers: approvers
         }}
      end

    %__MODULE__{installations: installations}
  end

  defimpl WardrikChannel.Installations do
    def fetch(%{installations: installations}, channel, _workspace),
      do: Map.fetch(installations, channel)

    def owned(%{installations: installations}, channel, owner),
      do: for({^channel, %Installation{owner: ^owner} = held} <- installations, do: held)

    def put(_config, %Installation{channel: channel}),
      do: {:error, "#{channel} is installed from its token in the config, and in no other way."}

    def delete(_config, _channel, _workspace), do: :ok
  end
end
