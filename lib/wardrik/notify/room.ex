defmodule Wardrik.Notify.Room do
  @moduledoc """
  Posts each notice in a room of one of the Wardrik's channels, through the channel's
  `c:Wardrik.Channel.notify/4`:

      ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}

  `approvers` are whom a parked turn's notice asks, as the channel names people. A route to
  `slack:#updates` posts there the same way, asking nobody by name.
  """

  @behaviour Wardrik.Notify

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    channel = Keyword.fetch!(opts, :channel)

    with {:ok, {module, channel_opts}} <-
           Wardrik.Operations.Channels.fetch(opts[:wardrik], channel),
         true <- posts?(module) do
      module.notify(
        channel_opts,
        Keyword.fetch!(opts, :room),
        notice,
        Keyword.get(opts, :approvers, [])
      )
    else
      :error -> {:skip, "but there's no channel #{channel} here"}
      false -> {:skip, "but the channel #{channel} posts no notices"}
    end
  end

  defp posts?(module) do
    Code.ensure_loaded(module)
    function_exported?(module, :notify, 4)
  end
end
