defmodule WardrikTriggers.Run do
  @moduledoc """
  Runs one due trigger or one webhook request. Reads feeds, asks the agent, and reports the status
  to the target and to telemetry.
  """

  require Logger

  alias WardrikTriggers.Feed
  alias WardrikTriggers.Records
  alias WardrikTriggers.Target
  alias WardrikTriggers.Trigger
  alias WardrikTriggers.Webhook

  @lateness 60
  @outside ["outside"]
  @remembered 500

  @doc """
  Runs `:agent_id`'s `:trigger`, which was due at `:due`, at `:now`.

      Run.clock(settings, agent_id: "agt_digest", trigger: trigger, due: due, now: now)

  A run more than a minute late with `missed: :skip` returns `:missed` and asks nothing.
  """
  @spec clock(map(),
          agent_id: String.t(),
          trigger: Trigger.t(),
          due: DateTime.t(),
          now: DateTime.t()
        ) :: Trigger.status()
  def clock(settings, args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    %Trigger{} = trigger = Keyword.fetch!(args, :trigger)
    now = Keyword.fetch!(args, :now)
    due = Keyword.fetch!(args, :due)

    status = ran(settings, agent_id, trigger, DateTime.diff(now, due) > @lateness)
    fired(settings, agent_id, trigger.name, status)
  end

  @doc "Asks the agent about a webhook request. See `WardrikTriggers.deliver/2`."
  @spec webhook(map(), agent_id: String.t(), name: String.t(), request: Webhook.request()) ::
          :ok | {:error, :not_found | :busy | :no_agent | :failed}
  def webhook(settings, args) do
    agent_id = Keyword.fetch!(args, :agent_id)
    name = Keyword.fetch!(args, :name)
    request = Keyword.fetch!(args, :request)

    with {:ok, record} <- record(settings, agent_id, name),
         %Trigger{webhook: %{} = webhook} = trigger <- Records.trigger(record),
         :ok <- verified(settings, agent_id, trigger, webhook, request) do
      id = Webhook.id(request)

      if id in Map.get(record, "delivered", []),
        do: :ok,
        else: delivered(settings, agent_id, trigger, id, request)
    else
      %Trigger{} -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp ran(_settings, _agent_id, %Trigger{missed: :skip}, true), do: :missed

  defp ran(settings, agent_id, %Trigger{feeds: [_ | _]} = trigger, _late),
    do: read(settings, agent_id, trigger)

  defp ran(settings, agent_id, trigger, _late),
    do: ask(settings, agent_id, trigger, prompt(trigger), [])

  defp read(settings, agent_id, trigger) do
    record = Records.lookup(settings.store, agent_id: agent_id, name: trigger.name)
    kept = if record, do: Map.get(elem(record, 0), "feeds", %{}), else: %{}
    read = Map.new(trigger.feeds, &{&1, fetch(settings, &1, Map.get(kept, &1))})
    new = for {_url, {:ok, entries, _state}} <- read, entry <- entries, do: entry

    :ok =
      Records.update(
        settings.store,
        [agent_id: agent_id, name: trigger.name],
        &Map.put(&1, "feeds", feeds(kept, read))
      )

    cond do
      Enum.all?(read, &match?({_url, {:error, _why}}, &1)) -> :failed
      new == [] -> :nothing_new
      true -> ask(settings, agent_id, trigger, Feed.prompt(prompt(trigger), new), @outside)
    end
  end

  defp fetch(settings, url, kept) do
    headers = conditional(kept)

    case Req.get(
           url,
           [headers: headers, retry: :transient, max_retries: 3] ++ settings.req_options
         ) do
      {:ok, %{status: 304}} -> {:ok, [], kept}
      {:ok, %{status: 200, body: body} = response} -> fresh(url, body, response, kept)
      {:ok, %{status: status}} -> unread(url, "it answered #{status}")
      {:error, error} -> unread(url, Exception.message(error))
    end
  end

  defp fresh(url, body, response, kept) do
    case Feed.parse(body) do
      {:ok, entries} -> noted(entries, response, kept)
      {:error, why} -> unread(url, why)
    end
  end

  defp noted(entries, response, nil),
    do: {:ok, [], state(response, Enum.take(Enum.map(entries, & &1.id), @remembered))}

  defp noted(entries, response, kept) do
    {new, seen} = Feed.unseen(entries, kept["seen"])
    {:ok, new, state(response, seen)}
  end

  defp unread(url, why) do
    Logger.warning("The feed #{url} wasn't read: #{why}")
    {:error, why}
  end

  defp state(response, seen) do
    %{
      "seen" => seen,
      "etag" => List.first(Req.Response.get_header(response, "etag")),
      "modified" => List.first(Req.Response.get_header(response, "last-modified"))
    }
  end

  defp conditional(nil), do: []

  defp conditional(kept) do
    [{"if-none-match", kept["etag"]}, {"if-modified-since", kept["modified"]}]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp feeds(kept, read) do
    Map.new(read, fn
      {url, {:ok, _entries, state}} -> {url, state}
      {url, {:error, _why}} -> {url, Map.get(kept, url)}
    end)
    |> Map.reject(fn {_url, state} -> is_nil(state) end)
  end

  defp record(settings, agent_id, name) do
    case Records.lookup(settings.store, agent_id: agent_id, name: name) do
      {record, _vsn} -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  defp verified(settings, agent_id, trigger, webhook, request) do
    with {:ok, secret} <- resolve_secret(settings, agent_id, webhook.secret),
         :ok <-
           Webhook.verify(request,
             verify: webhook.verify,
             secret: secret,
             now: DateTime.utc_now()
           ) do
      :ok
    else
      {:error, why} ->
        Logger.info("A request to #{agent_id}'s trigger #{trigger.name} didn't verify: #{why}")
        {:error, :not_found}
    end
  end

  defp resolve_secret(%{target: {module, opts}}, agent_id, "${" <> named) do
    secret = %Target.Secret{agent: agent_id, name: String.trim_trailing(named, "}")}

    case module.resolve_secret(secret, opts) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, "its secret #{named} isn't held"}
    end
  end

  defp delivered(settings, agent_id, trigger, id, request) do
    status = ask(settings, agent_id, trigger, Webhook.prompt(prompt(trigger), request), @outside)
    fired(settings, agent_id, trigger.name, status)

    if status == :asked do
      remember =
        &Map.update(&1, "delivered", [id], fn ids -> Enum.take([id | ids], @remembered) end)

      :ok = Records.update(settings.store, [agent_id: agent_id, name: trigger.name], remember)
    end

    answered(status)
  end

  defp answered(:asked), do: :ok
  defp answered(status), do: {:error, status}

  defp ask(%{target: {module, opts}}, agent_id, trigger, prompt, labels) do
    ask = %Target.Ask{
      agent: agent_id,
      prompt: prompt,
      trigger: trigger.name,
      overlap: trigger.overlap,
      labels: labels
    }

    case module.ask(ask, opts) do
      {:error, reason} ->
        Logger.warning("#{agent_id}'s trigger #{trigger.name} failed: #{inspect(reason)}")
        :failed

      status ->
        status
    end
  end

  defp prompt(%Trigger{prompt: nil, prompt_file: file}), do: "Read #{file}, and do what it says."
  defp prompt(%Trigger{prompt: prompt}), do: prompt

  defp fired(%{target: {module, opts}}, agent_id, name, status) do
    :ok = module.fired(%Target.Fired{agent: agent_id, trigger: name, status: status}, opts)

    :telemetry.execute([:wardrik_triggers, :fired], %{}, %{
      agent_id: agent_id,
      trigger: name,
      status: status
    })

    status
  end
end
