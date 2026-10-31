defmodule Wardrik.Notify.Webhook do
  @options [
    url: [type: :string, required: true, doc: "Where to post."],
    secret: [
      type: {:or, [:string, nil]},
      doc: """
      Signs the body. The `x-wardrik-signature` header is then `sha256=` followed by the hex
      HMAC-SHA256 of the body. See `sign/2`.
      """
    ],
    req_options: [type: :keyword_list, default: [], doc: "Merged into the `Req` request."]
  ]

  @moduledoc """
  Posts notices as JSON to a URL.

      audit: {Wardrik.Notify.Webhook, url: "https://hooks.example.com/wardrik", secret: secret}

  The body is `Wardrik.Notice.json/1`. The `x-wardrik-event` header names the event. Any status
  other than 2xx is a failure.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Notify

  alias Wardrik.Notice

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    with {:ok, opts} <- Wardrik.Notify.options(opts, @options), do: posted(notice, opts)
  end

  defp posted(notice, opts) do
    body = notice |> Notice.json() |> JSON.encode!()

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
        opts[:req_options]
      )

    case Req.post(opts[:url], options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the `x-wardrik-signature` value for `body` signed with `secret`.

      Wardrik.Notify.Webhook.sign(secret, body)
      #=> "sha256=9f86d0..."
  """
  @spec sign(String.t(), iodata()) :: String.t()
  def sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp signature(_body, nil), do: []
  defp signature(body, secret), do: [{"x-wardrik-signature", sign(secret, body)}]
end
