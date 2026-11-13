defmodule Wardrik.Notify.Webhook do
  @options [
    url: [type: :string, required: true, doc: "Where to post."],
    secret: [
      type: {:or, [:string, {:tuple, [{:in, [:secret]}, :string]}, nil]},
      doc:
        "Signs the body in `x-wardrik-signature`, as a string or `{:secret, name}`. See `sign/2`."
    ],
    req_options: [type: :keyword_list, default: [], doc: "Merged into the `Req` request."]
  ]

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  Posts notices as JSON to a URL.

      audit: {Wardrik.Notify.Webhook, url: "https://hooks.example.com/wardrik", secret: {:secret, "HOOK_SECRET"}}

    * The body is `Wardrik.Notice.json/1`.
    * `x-wardrik-event` names the event.
    * Any status but 2xx is a failure, and retried.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Notify

  alias Wardrik.Notice

  @impl Wardrik.Notify
  def schema, do: @options

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    body =
      notice
      |> Notice.json()
      |> JSON.encode!()

    options =
      Keyword.merge(
        [
          body: body,
          headers: [
            {"content-type", "application/json"},
            {"x-wardrik-event", Notice.event(notice)}
            | signature(body, opts[:secret])
          ],
          retry: false,
          receive_timeout: 10_000
        ],
        Keyword.get(opts, :req_options, [])
      )

    case Req.post(opts[:url], options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the `x-wardrik-signature` for `body`: `sha256=` and its hex HMAC-SHA256.

      Wardrik.Notify.Webhook.sign(secret, body)
      #=> "sha256=9f86d0..."
  """
  @spec sign(String.t(), iodata()) :: String.t()
  def sign(secret, body) do
    mac = :crypto.mac(:hmac, :sha256, secret, body)
    "sha256=" <> Base.encode16(mac, case: :lower)
  end

  defp signature(_body, nil), do: []
  defp signature(body, secret), do: [{"x-wardrik-signature", sign(secret, body)}]
end
