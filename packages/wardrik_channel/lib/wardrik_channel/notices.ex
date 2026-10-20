defmodule WardrikChannel.Notices do
  @moduledoc """
  Posts notices in rooms through a channel's adapter: as a `WardrikNotify`
  target, in one room of one workspace, and as the `WardrikNotify.Rooms` a
  route's rooms are posted in, each in a workspace of the agent's own
  owner.

  As a target:

      ops: {WardrikChannel.Notices,
        channel: {WardrikSlack, app_token: "xapp-…"},
        installation: installation,
        room: "#ops",
        approvers: ["@maria"]}

  `:channel` is the channel, as its adapter and the options its `config/1`
  answered; the daemon finds it by the name `config.yaml` gives it.
  `:installation` is the `WardrikChannel.Installation` of the workspace to
  post in, `:room` where in it, and `:approvers` whom a notice asks, as the
  channel names people. Who may answer it is what the token the host's
  `Wardrik.Issuer` issues them allows.

  As the rooms, it holds the host's `:channels`, by name, and their
  `:installations`, and `WardrikChannel.attach/2` registers it on the
  host. A route to `slack:#updates` posts in `#updates` through the
  channel `slack`, in a workspace `WardrikChannel.Installations.owned/3`
  answers for the owner nearest the agent: its user, its org, then every
  org, `*`. Where there is none, it posts nothing. It asks nobody.
  """

  @behaviour WardrikNotify

  alias WardrikChannel.Installations
  alias WardrikChannel.Outbound

  @enforce_keys [:channels, :installations]
  defstruct [:channels, :installations]

  @type t() :: %__MODULE__{
          channels: %{String.t() => WardrikChannel.channel()},
          installations: Installations.t()
        }

  @impl WardrikNotify
  def deliver(notice, opts) do
    {adapter, channel} = Keyword.fetch!(opts, :channel)

    outbound = %Outbound{
      installation: Keyword.fetch!(opts, :installation),
      room: Keyword.fetch!(opts, :room),
      body: {:notice, notice},
      approvers: Keyword.get(opts, :approvers, [])
    }

    with {:ok, _posted} <-
           adapter.deliver(outbound, Keyword.merge(Keyword.take(opts, [:req_options]), channel)),
         do: :ok
  end

  defimpl WardrikNotify.Rooms do
    alias Wardrik.AgentAddress
    alias Wardrik.AgentID
    alias Wardrik.Resource

    def post(notices, %{channel: channel, room: room}, notice, opts) do
      with {:ok, adapter} <- Map.fetch(notices.channels, channel),
           [installation | _] <- holding(notices.installations, channel, notice.agent) do
        WardrikChannel.Notices.deliver(
          notice,
          [channel: adapter, installation: installation, room: room] ++ opts
        )
      else
        :error -> {:skip, "which names no channel of this host's"}
        [] -> {:skip, "but #{channel} is installed in no workspace of its owner's"}
      end
    end

    # The owner nearest the agent first: its user, its org, every org.
    defp holding(installations, channel, agent) do
      resource = agent |> AgentAddress.agent() |> AgentID.resource()

      [Resource.owner(resource), Resource.org(resource), Resource.parse!("*")]
      |> Enum.uniq()
      |> Enum.flat_map(&Installations.owned(installations, channel, &1))
    end
  end
end
