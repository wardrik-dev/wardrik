defmodule Wardrik.Test.HTTP do
  @moduledoc "Starts a Wardrik for a test, signs Maria in to it, and stubs the model's answers."

  import ExUnit.Callbacks, only: [start_supervised!: 1]
  import Plug.Conn
  import Plug.Test

  def start_wardrik(context) do
    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"

    start_supervised!({Wardrik.Store, store})

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         [
           name: name,
           authorizer: {Wardrik.Test.Allow, []},
           resolver: {Wardrik.Test.Owned, name},
           store: store,
           deployment: "test",
           vault_keys: [Wardrik.Vault.generate_key()],
           channels: Map.get(context, :channels, [])
         ] ++ Keyword.take(Map.to_list(context), [:oauth])
       )}
    )

    secret = Wardrik.Test.HTTP.Authenticator.start(name, "acme/@maria")
    %{wardrik: name, owner: Wardrik.as(name, "acme/@maria"), secret: secret}
  end

  @doc "Returns `Wardrik.HTTP`'s options for the test's Wardrik, with `opts`."
  def http(context, opts \\ []),
    do: [wardrik: context.wardrik, authenticator: {Wardrik.Test.HTTP.Authenticator, []}] ++ opts

  def answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    Mimic.stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    Mimic.stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  def answer(text),
    do: %ReqLLM.Response{
      id: "resp",
      model: "test",
      context: nil,
      message: ReqLLM.Context.assistant(text)
    }

  def request(context, method, path, body \\ nil, headers \\ []) do
    opts =
      context
      |> http()
      |> Wardrik.HTTP.init()

    method
    |> conn(path, encoded(body))
    |> put_req_header("authorization", "Bearer " <> context.secret)
    |> put_req_header("content-type", "application/json")
    |> merge_req_headers(headers)
    |> Wardrik.HTTP.call(opts)
  end

  def body(conn), do: JSON.decode!(conn.resp_body)

  @doc "Returns `id` as one path segment, with everything but unreserved characters encoded."
  def segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp encoded(nil), do: ""
  defp encoded(body) when is_binary(body), do: body
  defp encoded(body), do: JSON.encode!(body)
end

defmodule Wardrik.Test.HTTP.Authenticator do
  @moduledoc "Takes the secrets a test signs principals in with, as `Authorization: Bearer`, until one is revoked."

  @behaviour Wardrik.HTTP.Authenticator

  import Plug.Conn, only: [get_req_header: 2]

  @doc "Signs `principal` in to the test's Wardrik `name`. Returns the secret it sends."
  def start(name, principal) do
    signed_in = signed_in(name)

    ExUnit.Callbacks.start_supervised!(%{
      id: signed_in,
      start: {Agent, :start_link, [fn -> %{} end, [name: signed_in]]}
    })

    sign_in(name, principal)
  end

  @doc "Signs `principal` in too. Returns the secret it sends."
  def sign_in(name, principal) do
    unique = System.unique_integer([:positive])
    secret = "secret-" <> Integer.to_string(unique)

    name
    |> signed_in()
    |> Agent.update(&Map.put(&1, secret, principal))

    secret
  end

  @doc "Signs out whoever sends `secret`."
  def revoke(name, secret) do
    name
    |> signed_in()
    |> Agent.update(&Map.delete(&1, secret))
  end

  @impl Wardrik.HTTP.Authenticator
  def authenticate(%{conn: conn, wardrik: wardrik}, _opts) do
    signed_in = signed_in(wardrik)

    with ["Bearer " <> secret] <- get_req_header(conn, "authorization"),
         principal when is_binary(principal) <- Agent.get(signed_in, &Map.get(&1, secret)) do
      {:ok, Wardrik.as(wardrik, principal)}
    else
      _unknown -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end

  defp signed_in(name), do: Module.concat(name, SignedIn)
end

defmodule Wardrik.Test.HTTP.Channel do
  @moduledoc "A channel that answers each request with where it was sent, its body, and its signature."
  @behaviour Wardrik.Channel

  @impl Wardrik.Channel
  def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> nil end]}}

  @impl Wardrik.Channel
  def request(%{path: path, body: body, headers: headers}, _opts) do
    %{
      status: 200,
      headers: %{"content-type" => "text/plain"},
      body: "#{path} #{body} #{headers["x-slack-signature"]}"
    }
  end
end
