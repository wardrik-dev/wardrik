defmodule WardrikOAuth.Callback do
  @moduledoc """
  The pages an authorization server sends a browser back to, under the
  deployment's redirect URL.

      WardrikOAuth.new(redirect: [url: "https://agents.example.com/oauth"])

  Each provider has a path of its own under the redirect URL, so
  `https://agents.example.com/oauth/callback/github` is the redirect URI to
  register for the `github` provider, and a code that comes back to it
  finishes only a `github` flow. A URL on loopback is this machine's, as
  RFC 8252 has a native application's: the browser is on the same machine,
  and the link is opened in it.

  The host serves `pages/1` among its routes, as `WardrikOAuth.attach/2`
  has it, on a listener of its own, as the daemon does on its HTTP API. They are under the URL's own path, so a front that ends
  TLS, such as Caddy, passes requests on as they came.
  `WardrikOAuth.finish/3` finds a flow any node of the cluster started, so
  any node may serve them.

  A callback's code, `state` and `iss` go to `WardrikOAuth.finish/3`, and
  the page tells the person to go back to their agent. What a server sent
  that is shown on the page is escaped. `check` answers with the nonce it
  was sent, so `check/2` can tell that the URL reaches it. A callback for a
  provider not configured gets a 404, and a callback carrying no code a 400.
  Every page is kept from caches, referrers and frames, and loads nothing.

  A host with a web surface of its own may serve the callback there
  instead, calling `WardrikOAuth.finish/3` from its own controller.
  """

  alias WardrikOAuth.Callback.Page

  @nonce ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc "The redirect URI `oauth` registers for `provider`."
  @spec redirect_uri(WardrikOAuth.t(), String.t()) :: String.t()
  def redirect_uri(oauth, provider) when is_binary(provider),
    do: url(oauth) <> "/callback/" <> URI.encode(provider, &URI.char_unreserved?/1)

  @doc "The deployment's redirect URL, which every provider's redirect URI is under."
  @spec url(WardrikOAuth.t()) :: String.t()
  def url(%WardrikOAuth{redirect: redirect}),
    do: redirect |> Keyword.fetch!(:url) |> String.trim_trailing("/")

  @doc "Whether the browser comes back to this machine: the URL names loopback."
  @spec loopback?(WardrikOAuth.t()) :: boolean()
  def loopback?(oauth), do: URI.parse(url(oauth)).host in ["127.0.0.1", "localhost", "::1"]

  @doc """
  Whether a provider may send a browser back to `url`: https, or http on
  this machine's own loopback, with nothing after its path.
  """
  @spec redirect?(String.t()) :: boolean()
  def redirect?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{userinfo: nil, query: nil, fragment: nil} = uri -> secure?(uri.scheme, uri.host)
      _other -> false
    end
  end

  defp secure?("https", host), do: host not in [nil, ""]
  defp secure?("http", host), do: host in ["127.0.0.1", "localhost", "::1"]
  defp secure?(_scheme, _host), do: false

  @doc "The path segments every page is served under: the redirect URL's own."
  @spec prefix(WardrikOAuth.t()) :: [String.t()]
  def prefix(oauth),
    do:
      oauth
      |> url()
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> String.split("/", trim: true)

  @doc """
  The pages a host serves, each as the segments a request's path begins
  with and the plug that answers it: `callback` and `check`, under the
  redirect URL's own path, both `WardrikOAuth.Callback.Page`.
  """
  @spec pages(WardrikOAuth.t()) :: [{[String.t()], {module(), keyword()}}]
  def pages(oauth),
    do: for(page <- ["callback", "check"], do: {prefix(oauth) ++ [page], {Page, oauth: oauth}})

  @doc """
  Whether `url`, the deployment's redirect URL, reaches these pages: asks
  its `check` page with a nonce of its own, through whatever is in front.
  `req_options` are merged into the request.
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check(url, req_options \\ []) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    target = String.trim_trailing(url, "/") <> "/check?nonce=" <> nonce

    case Req.get(target, Keyword.merge([retry: false, redirect: false], req_options)) do
      {:ok, %Req.Response{status: 200, body: "wardrik " <> ^nonce}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{target} answered #{status}, not this daemon"}

      {:error, reason} ->
        {:error, "#{target} did not answer: #{Exception.message(reason)}"}
    end
  end

  @doc """
  What a callback for `provider` carrying `params` is answered with: a status
  and the message shown on the page.
  """
  @spec answer(String.t(), map()) :: {pos_integer(), String.t()}
  def answer(_provider, %{"error" => error} = params),
    do: {400, "#{error}: #{params["error_description"] || "no reason given"}"}

  def answer(provider, %{"code" => code, "state" => state} = params)
      when is_binary(code) and is_binary(state) do
    case WardrikOAuth.finish(state, code, provider: provider, iss: params["iss"]) do
      {:ok, name} ->
        {200, "#{name} is connected. Go back to your agent."}

      {:error, reason} ->
        {400, "That did not work (#{tag(reason)}). Start again from your agent."}
    end
  end

  def answer(_provider, _params), do: {400, "That callback carried no code."}

  @doc "What `check` answers for `params`: the nonce it was sent, back."
  @spec checked(map()) :: {pos_integer(), String.t()}
  def checked(%{"nonce" => nonce}) when is_binary(nonce) do
    if Regex.match?(@nonce, nonce), do: {200, "wardrik " <> nonce}, else: {400, "bad nonce"}
  end

  def checked(_params), do: {400, "no nonce"}

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(_reason), do: :failed
end
