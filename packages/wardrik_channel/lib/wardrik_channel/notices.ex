defmodule WardrikChannel.Notices do
  @moduledoc """
  A `WardrikNotify` target that posts each notice in a room, through a
  channel's adapter.

      ops: {WardrikChannel.Notices,
        channel: {WardrikSlack, token: "xoxb-…", app_token: "xapp-…"},
        room: "#ops",
        approvers: ["@maria"]}

  `:channel` is the channel, as its adapter and the options its `config/1`
  answered; the daemon finds it by the name `config.yaml` gives it. `:room` is
  where in it, and `:approvers` whom a notice asks, as the channel names
  people. Who may answer it is what the host's `Wardrik.Grants` says.
  """

  @behaviour WardrikNotify

  alias WardrikChannel.Outbound

  @impl WardrikNotify
  def deliver(notice, opts) do
    {adapter, channel} = Keyword.fetch!(opts, :channel)

    outbound = %Outbound{
      room: Keyword.fetch!(opts, :room),
      body: {:notice, notice},
      approvers: Keyword.get(opts, :approvers, [])
    }

    with {:ok, _posted} <-
           adapter.deliver(outbound, Keyword.merge(Keyword.take(opts, [:req_options]), channel)),
         do: :ok
  end
end
