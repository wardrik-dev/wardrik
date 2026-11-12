defmodule WardrikDaemon.Webhook do
  @options [
    url: [type: :string, required: true, doc: "Where to post."],
    owner: [type: :string, required: true, doc: "Who added it, whose vault holds its secret."],
    secret: [type: :string, doc: "The name of the secret that signs each notice."]
  ]

  @moduledoc """
  Posts notices to a webhook an org or person added. See `WardrikDaemon.NotifyTargets`.

    * The URL is checked on every send, since its address can change.
    * The secret is read from the owner's vault on every send.
    * It posts as `Wardrik.Notify.Webhook` does, and never follows redirects.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Notify

  alias WardrikCore.Principal

  @impl Wardrik.Notify
  def schema, do: @options

  @impl Wardrik.Notify
  def deliver(notice, opts) do
    running = Wardrik.Instance.fetch!(opts[:wardrik])

    with :ok <- reachable(running, opts[:url]),
         {:ok, secret} <- signing(running, opts[:owner], opts[:secret]) do
      Wardrik.Notify.Webhook.deliver(notice,
        wardrik: opts[:wardrik],
        target: opts[:target],
        url: opts[:url],
        secret: secret,
        req_options: [redirect: false]
      )
    end
  end

  defp reachable(running, url) do
    case running.egress.(url) do
      :ok -> :ok
      {:error, why} -> {:skip, "but it can't be reached: #{why}"}
    end
  end

  defp signing(_running, _owner, nil), do: {:ok, nil}

  defp signing(running, owner, name) do
    vault = Wardrik.vault(running)

    case WardrikVault.fetch(vault, %Principal{id: owner}, name, kind: :signing_secret) do
      {:ok, secret} -> {:ok, secret}
      {:error, _reason} -> {:skip, "but #{owner} holds no secret #{name} to sign it with"}
    end
  end
end
