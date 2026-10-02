defmodule WardrikNotify.Webhook do
  @moduledoc """
  Posts each notice as JSON to a URL.

      audit: {WardrikNotify.Webhook, url: "https://hooks.example.com/wardrik", secret: "…"}

  The body is `WardrikNotify.Notice.to_map/1`, and the `x-wardrik-event` header
  names the event. With a `:secret`, `x-wardrik-signature` is `sha256=` and the
  hex HMAC-SHA256 of the body under it, so a receiver can tell the notice
  came from this daemon. A failed request is retried three times.
  """

  @behaviour WardrikNotify

  alias WardrikNotify.Notice

  @receive_timeout 10_000

  @impl WardrikNotify
  def deliver(%Notice{} = notice, opts) do
    body = notice |> Notice.to_map() |> JSON.encode!()

    options =
      [
        body: body,
        headers:
          [{"content-type", "application/json"}, {"x-wardrik-event", "turn_#{notice.kind}"}] ++
            signature(body, opts[:secret]),
        retry: :transient,
        max_retries: 3,
        receive_timeout: @receive_timeout
      ]
      |> Keyword.merge(WardrikNotify.Config.req_options())

    case Req.post(Keyword.fetch!(opts, :url), options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signature(_body, nil), do: []

  defp signature(body, secret) do
    [{"x-wardrik-signature", "sha256=" <> hmac(secret, body)}]
  end

  @doc "The hex HMAC-SHA256 of `body` under `secret`, as the signature header carries it."
  @spec hmac(String.t(), iodata()) :: String.t()
  def hmac(secret, body),
    do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
end
