defmodule Wardrik.Notify.Room do
  @options [
    channel: [type: :string, required: true, doc: "The channel's name."],
    room: [type: :string, required: true, doc: "The room, as the channel names it."]
  ]

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  Posts notices to a room in one of Wardrik's channels.

      ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops"}

    * A route to `slack:#updates` posts the same way.
    * It posts in the workspace `Wardrik.Resolved`'s `:channels` gives the agent, or skips.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Notify

  @impl Wardrik.Notify
  def schema, do: @options

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    wardrik = Wardrik.Instance.fetch!(opts[:wardrik])
    channel = opts[:channel]

    with {:ok, resolved} <- Wardrik.Resolver.defined(wardrik, notice.agent),
         {:ok, workspace} <- workspace(resolved, channel),
         {:ok, {module, channel_opts}} <- Wardrik.Operations.Channels.fetch(wardrik.name, channel),
         true <- posts?(module) do
      notification = %Wardrik.Channel.Notification{
        workspace: workspace,
        room: opts[:room],
        notice: notice
      }

      module.notify(notification, channel_opts)
    else
      {:skip, why} -> {:skip, why}
      {:error, error} -> {:error, error}
      :error -> {:skip, "but there's no channel #{channel} here"}
      false -> {:skip, "but the channel #{channel} posts no notices"}
    end
  end

  defp workspace(resolved, channel) do
    case Map.fetch(resolved.channels, channel) do
      {:ok, workspace} -> {:ok, workspace}
      :error -> {:skip, "but its resolver gives it no workspace in #{channel}"}
    end
  end

  defp posts?(module) do
    Code.ensure_loaded(module)
    function_exported?(module, :notify, 2)
  end
end
