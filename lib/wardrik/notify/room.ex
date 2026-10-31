defmodule Wardrik.Notify.Room do
  @options [
    channel: [type: :string, required: true, doc: "The channel's name."],
    room: [type: :string, required: true, doc: "The room, as the channel names it."],
    approvers: [
      type: {:list, :string},
      default: [],
      doc: "People a parked turn's notice asks, as the channel names them."
    ]
  ]

  @moduledoc """
  Posts notices to a room in one of Wardrik's channels, with `c:Wardrik.Channel.notify/4`.

      ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}

  A route to `slack:#updates` posts the same way, with no approvers.

  ## Options

  #{NimbleOptions.docs(@options)}

  Skips the notice if the channel doesn't exist or doesn't implement `notify/4`.
  """

  @behaviour Wardrik.Notify

  @impl Wardrik.Notify
  def schema, do: @options

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    channel = opts[:channel]

    with {:ok, {module, channel_opts}} <-
           Wardrik.Operations.Channels.fetch(opts[:wardrik], channel),
         true <- posts?(module) do
      module.notify(channel_opts, opts[:room], notice, opts[:approvers])
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
