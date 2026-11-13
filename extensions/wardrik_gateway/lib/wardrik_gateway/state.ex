defmodule WardrikGateway.State do
  @moduledoc false

  # Limits are per minute. A bucket lets a minute's worth through at once, then spaces the rest.
  @window 60_000

  @enforce_keys [:settings]
  defstruct [:settings, breakers: %{}, buckets: %{}]

  @type t() :: %__MODULE__{settings: map(), breakers: map(), buckets: map()}
  @type outcome() ::
          {:ok, non_neg_integer()} | {:limited, non_neg_integer()} | :failed | :hopeless
  @type event() :: {[atom()], map()}

  @spec new(map()) :: t()
  def new(settings), do: %__MODULE__{settings: settings}

  @spec configure(t(), map()) :: t()
  def configure(state, settings), do: %{state | settings: settings}

  @doc "Returns the models a call to `model` tries, in order, and how long it may wait in all."
  @spec plan(t(), String.t()) :: {[String.t()], non_neg_integer()}
  def plan(%__MODULE__{settings: settings}, model),
    do: {[model | Map.get(settings.fallbacks, model, [])], settings.wait}

  @doc """
  Admits a call to the first of `models` whose breaker lets it through and whose provider has room
  within `remaining` milliseconds, and reserves its place. Otherwise returns the soonest wait.
  """
  @spec admit(t(), [String.t()], non_neg_integer(), integer()) ::
          {{:go, String.t(), non_neg_integer()} | {:wait, non_neg_integer()}, t()}
  def admit(state, models, remaining, now) do
    Enum.reduce_while(models, {{:wait, nil}, state}, fn model, {{:wait, soonest}, state} ->
      case breaker(state, model, now) do
        {:open, wait} ->
          {:cont, {{:wait, sooner(soonest, wait)}, state}}

        {:closed, breakers} ->
          roomy(%{state | breakers: breakers}, model, remaining, now, soonest)
      end
    end)
  end

  defp roomy(state, model, remaining, now, soonest) do
    provider = provider(model)
    {wait, bucket} = bucket(state, provider, now)

    if wait <= remaining,
      do: {:halt, {{:go, model, wait}, put_in(state.buckets[provider], bucket)}},
      else: {:cont, {{:wait, sooner(soonest, wait)}, state}}
  end

  defp sooner(nil, wait), do: wait
  defp sooner(soonest, wait), do: min(soonest, wait)

  @doc "Records how a call to `model` went. Returns the events it set off."
  @spec report(t(), String.t(), outcome(), integer()) :: {[event()], t()}
  def report(state, model, {:ok, tokens}, now) do
    events = if match?(%{until: _}, state.breakers[model]), do: [closed(model)], else: []
    state = %{state | breakers: Map.delete(state.breakers, model)}
    {events, charged(state, provider(model), tokens, now)}
  end

  def report(state, model, {:limited, wait}, now) do
    provider = provider(model)
    bucket = Map.get(state.buckets, provider, %{})
    held = max(Map.get(bucket, :held, now), now + wait)
    {[], put_in(state.buckets[provider], Map.put(bucket, :held, held))}
  end

  def report(state, model, :failed, now) do
    breaker = Map.get(state.breakers, model, %{failures: []})
    {events, breaker} = failed(breaker, state.settings.breaker, model, now)
    {events, put_in(state.breakers[model], breaker)}
  end

  def report(state, _model, :hopeless, _now), do: {[], state}

  # A breaker is closed (failures within the window), open until a time, or probing: one call
  # was let through after it opened, and the rest wait on its answer.
  defp breaker(state, model, now) do
    case Map.get(state.breakers, model) do
      %{until: until} when until > now -> {:open, until - now}
      %{until: _expired} -> {:closed, probing(state, model, now)}
      _closed -> {:closed, state.breakers}
    end
  end

  defp probing(state, model, now),
    do:
      Map.put(state.breakers, model, %{
        probing: true,
        until: now + state.settings.breaker.open_for
      })

  defp failed(%{probing: true}, settings, model, now),
    do: {[opened(model)], %{until: now + settings.open_for}}

  defp failed(%{until: _until} = open, _settings, _model, _now), do: {[], open}

  defp failed(%{failures: failures}, settings, model, now) do
    failures = [now | Enum.filter(failures, &(&1 > now - settings.within))]

    if length(failures) >= settings.failures,
      do: {[opened(model)], %{until: now + settings.open_for}},
      else: {[], %{failures: failures}}
  end

  defp opened(model), do: {[:wardrik_gateway, :breaker_opened], %{model: model}}
  defp closed(model), do: {[:wardrik_gateway, :breaker_closed], %{model: model}}

  defp bucket(state, provider, now) do
    limits = Map.get(state.settings.limits, provider, [])
    bucket = Map.get(state.buckets, provider, %{})
    held = max(Map.get(bucket, :held, now) - now, 0)
    {requests, bucket} = requested(bucket, limits[:requests_per_minute], now)
    tokens = max(Map.get(bucket, :tokens, now) - now - @window, 0)
    {ceil(Enum.max([held, requests, tokens])), bucket}
  end

  defp requested(bucket, nil, _now), do: {0, bucket}

  defp requested(bucket, per_minute, now) do
    interval = @window / per_minute
    due = max(Map.get(bucket, :requests, now), now)
    {max(due - now - (@window - interval), 0), Map.put(bucket, :requests, due + interval)}
  end

  defp charged(state, provider, tokens, now) do
    case state.settings.limits[provider][:tokens_per_minute] do
      nil ->
        state

      per_minute ->
        bucket = Map.get(state.buckets, provider, %{})
        spent = max(Map.get(bucket, :tokens, now), now) + tokens * @window / per_minute
        put_in(state.buckets[provider], Map.put(bucket, :tokens, spent))
    end
  end

  @doc ~s(Returns the provider of a model spec, as `"anthropic"` for `"anthropic:claude-haiku-4-5"`.)
  @spec provider(String.t()) :: String.t()
  def provider(model) do
    model
    |> String.split(":", parts: 2)
    |> hd()
  end
end
