defmodule Wardrik.Notify.Webhook do
  @moduledoc """
  Posts each notice as JSON to a URL, `Wardrik.Notice.json/1`, naming its event in
  `x-wardrik-event`:

      audit: {Wardrik.Notify.Webhook, url: "https://hooks.example.com/wardrik", secret: secret}

  With a `:secret`, `x-wardrik-signature` is `sha256=` and the hex HMAC-SHA256 of the body under
  it. An answer other than 2xx is a failure. `:req_options` are merged into the request.
  """

  @behaviour Wardrik.Notify

  alias Wardrik.Notice

  @impl Wardrik.Notify
  def deliver(notice, opts) do
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
        Keyword.get(opts, :req_options, [])
      )

    case Req.post(Keyword.fetch!(opts, :url), options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the signature of `body` under `secret`, as `x-wardrik-signature` carries it."
  @spec sign(String.t(), iodata()) :: String.t()
  def sign(secret, body),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  defp signature(_body, nil), do: []
  defp signature(body, secret), do: [{"x-wardrik-signature", sign(secret, body)}]
end
