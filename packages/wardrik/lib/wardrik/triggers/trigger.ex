defmodule Wardrik.Triggers.Trigger do
  @moduledoc """
  A trigger: when to ask an agent, and what. Decoded from a map with string keys.

      {:ok, trigger} =
        Wardrik.Triggers.Trigger.decode(%{
          "name" => "daily",
          "every" => "0 9 * * *",
          "timezone" => "America/Los_Angeles",
          "prompt" => "Write today's update."
        })

  A trigger has one of `every`, `at` or `webhook`, and `prompt` or `prompt_file`.

  ## Keys

    * `every` - a cron expression, as `"0 9 * * 1"` or `"@daily"`, or an interval of at least a
      minute, as `"30m"`, `"2h"` or `"1d"`.
    * `at` - a single time, as `"2026-11-17T09:00"` in `timezone`, or `"2026-11-17T17:00:00Z"`
      with an offset and no `timezone`. It runs once.
    * `webhook` - `%{"secret" => "${NAME}", "verify" => "shared"}`. `verify` is `"shared"`
      (default) or `"standard"`. See `Wardrik.Triggers.Webhook`.
    * `prompt` - what the agent is asked.
    * `prompt_file` - a file the agent is told to read and follow.
    * `name` - no `/`, `:` or whitespace. Defaults to `trigger-1`, `trigger-2`, ... by position.
    * `timezone` - the zone a cron expression or `at` is read in. Defaults to `"Etc/UTC"`.
    * `overlap` - what a run does while the agent is busy. `"skip"` leaves it alone, `"queue"` asks
      anyway, and `"settle"` cancels a turn waiting on an answer nobody gave, then asks, and skips
      otherwise. Defaults to `"settle"`, or `"queue"` for `at` or a webhook.
    * `missed` - `"run_once"` (default) runs once after missed runs. `"skip"` drops them.
    * `jitter` - up to this many seconds added to each run. Defaults to `0`.
    * `feed` - an RSS or Atom feed URL, or a list of them. Asks only about new entries.
  """

  alias Wardrik.Triggers.Clock

  @enforce_keys [:name, :prompt]
  defstruct [
    :name,
    :every,
    :at,
    :clock,
    :prompt,
    :prompt_file,
    :webhook,
    timezone: "Etc/UTC",
    overlap: :settle,
    missed: :run_once,
    jitter: 0,
    feeds: []
  ]

  @type t() :: %__MODULE__{
          name: String.t(),
          every: String.t() | nil,
          at: String.t() | nil,
          clock: Clock.t() | nil,
          prompt: String.t() | nil,
          prompt_file: String.t() | nil,
          webhook: %{secret: String.t(), verify: :shared | :standard} | nil,
          timezone: String.t(),
          overlap: :skip | :queue | :settle,
          missed: :run_once | :skip,
          jitter: non_neg_integer(),
          feeds: [String.t()]
        }

  @typedoc "How a run went. Matches the protocol's `trigger.fired` status."
  @type status() :: :asked | :nothing_new | :busy | :no_agent | :missed | :failed

  @keys ~w(name every at timezone prompt prompt_file overlap missed jitter feed webhook)
  @overlaps %{"skip" => :skip, "queue" => :queue, "settle" => :settle}
  @missed %{"run_once" => :run_once, "skip" => :skip}
  @verifies %{"shared" => :shared, "standard" => :standard}

  @doc """
  Decodes a trigger. Without a `"name"`, it's named `trigger-<index>`.

  Returns `{:error, message}` for an unknown key or invalid value.
  """
  @spec decode(map(), pos_integer()) :: {:ok, t()} | {:error, String.t()}
  def decode(fields, index \\ 1)

  def decode(fields, index) when is_map(fields) do
    with :ok <- known(fields),
         {:ok, name} <- name(Map.get(fields, "name", "trigger-#{index}")),
         {:ok, webhook} <- webhook(fields["webhook"]),
         {:ok, clock} <- clock(fields["every"], fields["at"], webhook),
         :ok <- timezone(fields, clock),
         :ok <- prompt(fields),
         {:ok, overlap} <- choice(fields, "overlap", @overlaps, default_overlap(clock, webhook)),
         {:ok, missed} <- choice(fields, "missed", @missed, :run_once),
         {:ok, feeds} <- feeds(Map.get(fields, "feed", [])),
         :ok <- fed(feeds, clock) do
      {:ok,
       %__MODULE__{
         name: name,
         every: fields["every"],
         at: fields["at"],
         clock: clock,
         prompt: fields["prompt"],
         prompt_file: fields["prompt_file"],
         webhook: webhook,
         timezone: Map.get(fields, "timezone", "Etc/UTC"),
         overlap: overlap,
         missed: missed,
         jitter: Map.get(fields, "jitter", 0),
         feeds: feeds
       }}
    end
  end

  def decode(_fields, _index), do: {:error, "a trigger is a map of #{Enum.join(@keys, ", ")}"}

  @doc "Encodes the trigger as a map with string keys, leaving out unset keys."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{} = trigger) do
    %{
      "name" => trigger.name,
      "every" => trigger.every,
      "at" => trigger.at,
      "timezone" => if(trigger.timezone != "Etc/UTC", do: trigger.timezone),
      "prompt" => trigger.prompt,
      "prompt_file" => trigger.prompt_file,
      "overlap" => Atom.to_string(trigger.overlap),
      "missed" => Atom.to_string(trigger.missed),
      "jitter" => if(trigger.jitter > 0, do: trigger.jitter),
      "feed" => if(trigger.feeds != [], do: trigger.feeds),
      "webhook" => webhook_json(trigger.webhook)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp known(fields) do
    case Map.keys(fields) -- @keys do
      [] -> :ok
      [key | _rest] -> {:error, "#{key} is not a setting of a trigger"}
    end
  end

  defp name(name) when is_binary(name) do
    if Regex.match?(~r/^[^\/:\s]+$/, name),
      do: {:ok, name},
      else: {:error, "a trigger's name holds no /, : or whitespace"}
  end

  defp name(_name), do: {:error, "a trigger's name is text"}

  defp webhook(nil), do: {:ok, nil}

  defp webhook(%{"secret" => "${" <> _rest = secret} = fields) do
    with {:ok, verify} <- choice(fields, "verify", @verifies, :shared),
         do: {:ok, %{secret: secret, verify: verify}}
  end

  defp webhook(_fields), do: {:error, "a webhook names its secret, as ${NAME}"}

  defp clock(nil, nil, nil), do: {:error, "a trigger has every, at, or a webhook"}
  defp clock(nil, nil, _webhook), do: {:ok, nil}
  defp clock(every, nil, nil) when is_binary(every), do: Clock.parse(every)
  defp clock(_every, nil, nil), do: {:error, "every is a cron expression or an interval"}
  defp clock(nil, at, nil), do: Clock.parse_at(at)
  defp clock(_every, _at, _webhook), do: {:error, "a trigger has one of every, at or a webhook"}

  defp timezone(%{"timezone" => timezone}, clock) do
    cond do
      not (is_binary(timezone) and Clock.zone?(timezone)) ->
        {:error, "#{inspect(timezone)} is not a time zone"}

      Clock.instant?(clock) ->
        {:error, "at has an offset, so it takes no timezone"}

      true ->
        :ok
    end
  end

  defp timezone(_fields, _clock), do: :ok

  defp prompt(%{"prompt" => prompt}) when is_binary(prompt), do: :ok
  defp prompt(%{"prompt_file" => file}) when is_binary(file), do: :ok
  defp prompt(_fields), do: {:error, "a trigger has a prompt or a prompt_file"}

  defp default_overlap({:at, _at}, _webhook), do: :queue
  defp default_overlap(_clock, nil), do: :settle
  defp default_overlap(_clock, _webhook), do: :queue

  defp choice(fields, key, choices, default) do
    case Map.fetch(fields, key) do
      :error -> {:ok, default}
      {:ok, value} -> chosen(Map.fetch(choices, value), key, choices)
    end
  end

  defp chosen({:ok, atom}, _key, _choices), do: {:ok, atom}

  defp chosen(:error, key, choices),
    do: {:error, "#{key} is one of #{Enum.map_join(choices, ", ", fn {name, _atom} -> name end)}"}

  defp feeds(url) when is_binary(url), do: {:ok, [url]}

  defp feeds(urls) when is_list(urls) do
    if Enum.all?(urls, &is_binary/1),
      do: {:ok, urls},
      else: {:error, "a feed is a URL, or a list of them"}
  end

  defp feeds(_urls), do: {:error, "a feed is a URL, or a list of them"}

  defp fed([_ | _], {:at, _at}), do: {:error, "a trigger with at has no feed"}
  defp fed(_feeds, _clock), do: :ok

  defp webhook_json(nil), do: nil

  defp webhook_json(%{secret: secret, verify: verify}),
    do: %{"secret" => secret, "verify" => Atom.to_string(verify)}
end
