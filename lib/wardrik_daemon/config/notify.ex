defmodule WardrikDaemon.Config.Notify do
  @moduledoc """
  Reads `config.yaml`'s `notify`: where agents' notices go.

      notify:
        retries: {attempts: 5, max_wait: 30000}
        targets:
          ops: {channel: slack, room: "#ops"}
          audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}

  `notify` takes `Wardrik.Notify`'s options. `targets` holds the deployment's targets, each by a
  name of your own, and each one of:

    * a room - `Wardrik.Notify.Room`'s options, with `channel` one of `channels`.
    * a webhook - `webhook`, holding `Wardrik.Notify.Webhook`'s options.

  A target's name can't hold `:`, which names a channel's room. A target tells the deployment's own
  org's agents unless `orgs` says otherwise.

  These are the deployment's targets. Orgs and people add webhooks of their own. See
  `WardrikDaemon.NotifyTargets`.
  """

  alias Wardrik.Notify.Room
  alias Wardrik.Notify.Webhook
  alias WardrikDaemon.Config.Options

  @doc "Returns Wardrik's `:notify` option from `section`. `channels` are the channels' names."
  @spec read(map(), [String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def read(section, channels) do
    Options.loaded([Wardrik.Notify, WardrikCore.Retry, Req.Steps])
    {targets, own} = Map.pop(section, "targets", %{})

    with :ok <- untargeted(own),
         {:ok, own} <- Options.each(own, &keywords/2),
         {:ok, own} <- Options.convert(Map.new(own), [], "notify"),
         {:ok, targets} <- targets(targets, channels),
         notify = [targets: targets] ++ own,
         {:ok, _settings} <- Options.built(fn -> Wardrik.Notify.settings(notify) end, "notify") do
      {:ok, notify}
    end
  end

  defp untargeted(own) do
    case Enum.find(own, fn {_name, value} -> is_map(value) and target?(value) end) do
      nil -> :ok
      {name, _target} -> {:error, "notify.#{name}: is a target, which goes in notify.targets"}
    end
  end

  defp target?(value), do: Map.has_key?(value, "channel") or Map.has_key?(value, "webhook")

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
        {:error, "#{path}: is a room, with channel and room, or a webhook, with url"}

      true ->
        typed(target, channels, path)
    end
  end

  defp typed(%{"webhook" => webhook} = target, _channels, path) when map_size(target) == 1 do
    with {:ok, opts} <- Options.validate(webhook, Webhook.schema(), "#{path}.webhook"),
         do: {:ok, {Webhook, opts}}
  end

  defp typed(%{"channel" => channel} = target, channels, path) do
    with {:ok, opts} <- Options.validate(target, Room.schema(), path) do
      if channel in channels,
        do: {:ok, {Room, opts}},
        else: {:error, "#{path}.channel: names none of channels"}
    end
  end

  defp typed(_target, _channels, path),
    do: {:error, "#{path}: is a room, with channel and room, or a webhook, with url"}
end
