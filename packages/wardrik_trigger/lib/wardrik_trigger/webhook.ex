defmodule WardrikTrigger.Webhook do
  @moduledoc """
  A trigger that a service sends requests, a webhook, when something
  happens there: it has no clock, and asks its agent as each request
  arrives, with the request's body under the prompt.

      WardrikTrigger.put(~A"acme/triage", WardrikTrigger.Webhook.new("issues",
        scheme: "github",
        secret: "GITHUB_SIGNING_SECRET",
        prompt: "A GitHub event is below. Triage it."))

  Written as text, as an agent file writes it:

      %{"webhook" => "github", "secret" => "${GITHUB_SIGNING_SECRET}", "prompt" => "..."}

  `scheme` is how the service signs what it sends, a
  `WardrikTrigger.Webhook.Scheme`: `github`, or `standard` for the Standard
  Webhooks spec that many services follow. `secret` names the secret it signs
  with, which is read for the trigger's agent as each request arrives, as
  `WardrikTrigger.secret/2` reads it, so it is kept in neither the trigger
  nor its definition. `overlap` is as a trigger on a clock has it, `:queue`
  by default, so a request that arrives while the agent runs is asked about
  after.

  A request reaches it through `WardrikTrigger.deliver/3`, and
  `WardrikTrigger.Webhook.Server` checks it. Each is a `WardrikTrigger.Item`,
  labelled `"outside"`: its id is the sender's delivery ID, its title the
  kind of event, and it shows the agent the body as it was sent, its first
  32,768 characters.
  """

  alias WardrikTrigger.Item
  alias WardrikTrigger.Webhook.Scheme

  require Logger

  @enforce_keys [:name, :prompt, :scheme, :secret]
  defstruct [:name, :prompt, :scheme, :secret, overlap: :queue]

  @type t() :: %__MODULE__{
          name: String.t(),
          prompt: String.t(),
          scheme: String.t(),
          secret: String.t(),
          overlap: :skip | :queue
        }

  @fields ~w(webhook secret prompt overlap)
  @shown 32_768

  @doc """
  The key the webhook trigger `name` of `agent` runs under, which
  `WardrikTrigger.deliver/3` finds it by: apart from a trigger on a clock of
  the same name, since a name holds no `/`.
  """
  @spec key(Wardrik.AgentID.t(), String.t()) :: String.t()
  def key(agent, name), do: "#{agent}//#{name}/webhook"

  @doc "The fields a webhook trigger written as text has beside the ones every trigger has."
  @spec keys() :: [String.t()]
  def keys, do: ["secret", "webhook"]

  @doc """
  A webhook trigger named `name`, with `:scheme`, `:secret`, `:prompt` and
  `:overlap` as above. Raises `ArgumentError` on one that does not read.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts) when is_list(opts) do
    %__MODULE__{
      name: WardrikTrigger.name!(name),
      prompt: WardrikTrigger.prompt!(Keyword.get(opts, :prompt)),
      scheme: scheme!(Keyword.get(opts, :scheme)),
      secret: secret!(Keyword.get(opts, :secret)),
      overlap: WardrikTrigger.overlap!(Keyword.get(opts, :overlap, :queue))
    }
  end

  defp scheme!(scheme) do
    schemes = Scheme.all()

    if is_binary(scheme) and Map.has_key?(schemes, scheme),
      do: scheme,
      else:
        raise(
          ArgumentError,
          "webhook is one of #{schemes |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
        )
  end

  defp secret!(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name),
      do: name,
      else: raise(ArgumentError, "a webhook's secret is a name, as GITHUB_SIGNING_SECRET")
  end

  defp secret!(other),
    do: raise(ArgumentError, "a webhook's secret is a name, got #{inspect(other)}")

  @doc """
  A webhook trigger named `name`, from fields written as text: `webhook`
  names the scheme, `secret` the secret as `${NAME}`, and `prompt` and
  `overlap` are as a trigger on a clock writes them. It takes no `every`,
  `missed` or `jitter`.
  """
  @spec decode(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def decode(name, fields) when is_map(fields) do
    with :ok <- only(fields),
         {:ok, secret} <- secret(fields["secret"]),
         {:ok, overlap} <- overlap(fields["overlap"]) do
      {:ok,
       new(name,
         scheme: fields["webhook"],
         secret: secret,
         prompt: fields["prompt"],
         overlap: overlap
       )}
    end
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  defp only(fields) do
    case fields |> Map.keys() |> Enum.reject(&(&1 in @fields)) |> Enum.sort() do
      [] ->
        :ok

      [key | _] ->
        {:error, "#{key} is not a setting of a webhook, which asks as each request arrives"}
    end
  end

  defp secret(text) when is_binary(text) do
    case Regex.run(~r/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/, text) do
      [_, name] -> {:ok, name}
      nil -> secret(nil)
    end
  end

  defp secret(_other), do: {:error, "a webhook has a secret, as ${NAME}"}

  defp overlap(nil), do: {:ok, :queue}
  defp overlap("skip"), do: {:ok, :skip}
  defp overlap("queue"), do: {:ok, :queue}
  defp overlap(_other), do: {:error, "overlap is one of skip, queue"}

  @doc """
  The item `request` holds for `agent`, or why it is not delivered:
  `:forbidden` where its signature does not match, and `:unavailable` where
  it cannot be checked now, as when the secret is not set.
  """
  @spec received(t(), Wardrik.Triggers.request(), Wardrik.AgentID.t()) ::
          {:ok, Item.t()} | {:error, :forbidden | :unavailable, String.t()}
  def received(%__MODULE__{} = hook, %{headers: headers, body: body}, agent) do
    with {:ok, module} <- module(hook.scheme),
         {:ok, secret} <- read(hook.secret, agent) do
      case module.verify(headers, body, secret) do
        {:ok, delivery} -> {:ok, item(delivery, body)}
        {:error, message} -> {:error, :forbidden, message}
      end
    end
  end

  defp module(scheme) do
    case Map.fetch(Scheme.all(), scheme) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unavailable, "No webhook scheme #{scheme} is loaded."}
    end
  end

  defp read(name, agent) do
    case WardrikTrigger.secret(name, agent) do
      secret when is_binary(secret) and secret != "" ->
        {:ok, secret}

      _unset ->
        Logger.warning("a webhook of #{agent} names the secret #{name}, which is not set")
        {:error, :unavailable, "The secret this webhook is checked with is not set."}
    end
  end

  defp item(%{id: id, event: event}, body) do
    %Item{id: id, title: event, at: DateTime.utc_now(), text: clip(body), labels: ["outside"]}
  end

  defp clip(body) do
    cond do
      not String.valid?(body) -> "(#{byte_size(body)} bytes that are not text)"
      String.length(body) <= @shown -> body
      true -> String.slice(body, 0, @shown) <> "…"
    end
  end
end

defimpl WardrikTrigger.Kind, for: WardrikTrigger.Webhook do
  alias WardrikTrigger.Webhook

  def key(hook, agent), do: Webhook.key(agent, hook.name)

  def child(hook, agent), do: {Webhook.Server, %Webhook.Server{agent: agent, hook: hook}}

  def encode(hook) do
    %{
      "name" => hook.name,
      "webhook" => hook.scheme,
      "secret" => "${#{hook.secret}}",
      "prompt" => hook.prompt,
      "overlap" => Atom.to_string(hook.overlap)
    }
  end
end
