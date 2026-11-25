defmodule WardrikDaemon.Config.Notify do
  @moduledoc """
  Reads `config.yaml`'s `notify`: where agents' notices go.

      notify:
        retries: {attempts: 5, max_wait: 30000}
        targets:
          ops: {channel: slack, room: "#ops"}
          audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}
          assistant: {agent: assistant}
          reports: {agent: assistant, conversation: reports}

    * `notify` takes `Wardrik.Notify`'s options.
    * A target is a room (`Wardrik.Notify.Room`'s options, `channel` from `channels`), a
      `webhook` (`Wardrik.Notify.Webhook`'s options), or an `agent`, by name, in the notifying
      agent's org (`WardrikDaemon.NotifyAgent`), notified in its main conversation or the
      one `conversation` names.
    * A target's name can't hold `:`.
    * Targets serve the deployment's org unless `orgs` says otherwise.
    * Orgs and people add their own webhooks. See Wardrik's `notify_targets.*` operations.
  """

  alias Wardrik.Notify.Room
  alias Wardrik.Notify.Webhook
  alias WardrikDaemon.Config.Options
  alias WardrikDaemon.NotifyAgent

  @doc "Returns Wardrik's `:notify` option from `section`. `channels` are the channels' names."
  @spec read(map(), [String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def read(section, channels) do
    Options.load_modules([Wardrik.Notify, WardrikCore.Retry, Req.Steps])
    {targets, own} = Map.pop(section, "targets", %{})

    with :ok <- check_targets(own),
         {:ok, own} <- Options.each(own, &keywords/2),
         {:ok, own} <-
           own
           |> Map.new()
           |> Options.convert([], "notify"),
         {:ok, targets} <- targets(targets, channels),
         notify = [targets: targets] ++ own,
         {:ok, _settings} <-
           Options.call_builder(fn -> Wardrik.Notify.settings(notify) end, "notify") do
      {:ok, notify}
    end
  end

  defp check_targets(own) do
    case Enum.find(own, fn {_name, value} -> is_map(value) and target?(value) end) do
      nil -> :ok
      {name, _target} -> {:error, "notify.#{name}: is a target, which goes in notify.targets"}
    end
  end

  defp target?(value),
    do: Enum.any?(["channel", "webhook", "agent"], &Map.has_key?(value, &1))

  defp keywords(name, map) when is_map(map), do: Options.convert(map, [], "notify.#{name}")
  defp keywords(_name, value), do: {:ok, value}

  defp targets(targets, channels) when is_map(targets),
    do: Options.each(targets, &target(&1, &2, channels))

  defp targets(_targets, _channels),
    do: {:error, "notify.targets: is a target for each name"}

  defp target(name, target, channels) do
    path = "notify.targets.#{name}"

    cond do
      String.contains?(name, ":") ->
        {:error, "#{path}: isn't a target's name, since : names a channel's room"}

      not is_map(target) ->
        {:error, "#{path}: is a room, with channel and room, a webhook, with url, or an agent"}

      true ->
        build_target(target, channels, path)
    end
  end

  defp build_target(%{"webhook" => webhook} = target, _channels, path)
       when map_size(target) == 1 do
    with {:ok, opts} <- Options.validate(webhook, Webhook.schema(), "#{path}.webhook"),
         do: {:ok, {Webhook, opts}}
  end

  defp build_target(%{"agent" => name} = target, _channels, path) do
    case Map.split(target, ["agent", "conversation"]) do
      {named, others} when map_size(others) == 0 ->
        build_agent_target(Map.delete(named, "agent"), name, path)

      _more ->
        {:error, "#{path}: is a room, with channel and room, a webhook, with url, or an agent"}
    end
  end

  defp build_agent_target(options, name, path) do
    named = Map.put(options, "name", name)

    with {:ok, opts} <- Options.validate(named, NotifyAgent.schema(), "#{path}.agent"),
         do: {:ok, {NotifyAgent, opts}}
  end

  defp build_target(%{"channel" => channel} = target, channels, path) do
    with {:ok, opts} <- Options.validate(target, Room.schema(), path) do
      if channel in channels,
        do: {:ok, {Room, opts}},
        else: {:error, "#{path}.channel: names none of channels"}
    end
  end

  defp build_target(_target, _channels, path),
    do: {:error, "#{path}: is a room, with channel and room, a webhook, with url, or an agent"}
end
