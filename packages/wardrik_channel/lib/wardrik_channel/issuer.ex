defmodule WardrikChannel.Issuer do
  @moduledoc """
  The token of someone in a channel's workspace, as `WardrikChannel.principal/2`
  names them: `reader` and `messenger` on the agents of the org the channel's
  installation there serves, and `approver` too where the installation's
  approvers name them. Someone in a workspace the channel isn't installed in
  holds nothing.

  `WardrikChannel.attach/2` registers one for each channel among the host's
  `:issuers`, by the channel's name, so an issuer that knows nothing of
  channels, such as a `use Wardrik` instance's, hands their people to it.
  """

  @enforce_keys [:channel, :installations]
  defstruct [:channel, :installations]

  @typedoc """
  What issues the people of one channel their tokens: its adapter and the
  options `config/1` answered, and the `WardrikChannel.Installations` its
  workspaces are found in.
  """
  @type t() :: %__MODULE__{
          channel: WardrikChannel.channel(),
          installations: WardrikChannel.Installations.t()
        }

  @everyone [:reader, :messenger]
  @deciders [:reader, :messenger, :approver]

  @doc false
  def issue(%__MODULE__{channel: channel, installations: installations}, principal) do
    {name, workspace, id} = WardrikChannel.person(principal)

    case WardrikChannel.Installations.fetch(installations, name, workspace) do
      {:ok, installation} ->
        member = WardrikChannel.Member.new(installation, id)
        agents = Wardrik.Resource.parse!("#{installation.owner}/agent/*")
        roles = roles(channel, installation, member)
        %Wardrik.Token{principal: principal, scope: [Wardrik.Role.bind(roles, [agents])]}

      :error ->
        %Wardrik.Token{principal: principal}
    end
  end

  defp roles(channel, installation, member) do
    include? = &WardrikChannel.include?(channel, &1, member)

    if WardrikChannel.Approvers.decides?(installation.approvers, include?),
      do: @deciders,
      else: @everyone
  end
end

defimpl Wardrik.Issuer, for: WardrikChannel.Issuer do
  def issue(issuer, principal, _opts), do: WardrikChannel.Issuer.issue(issuer, principal)
end
