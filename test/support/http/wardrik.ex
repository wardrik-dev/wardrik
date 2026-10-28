defmodule Wardrik.Test.HTTP do
  @moduledoc "Starts a Wardrik for a test, makes a token for it, and stubs the model's answers."

  import ExUnit.Callbacks, only: [start_supervised!: 1]
  import Plug.Conn
  import Plug.Test

  def start_wardrik(context) do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")
    name = :"wardrik #{context.test}"

    start_supervised!({WardrikStore, store})

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         name: name,
         store: store,
         deployment: "test",
         keys: [WardrikVault.generate_key()],
         oauth: Map.get(context, :oauth),
         channels: Map.get(context, :channels, [])
       )}
    )

    owner = Wardrik.as(name, "acme/@maria", roles: [:owner], resources: ["*"])
    {:ok, issued} = Wardrik.Tokens.create(owner, name: "test", roles: ["owner"], resources: ["*"])

    %{wardrik: name, owner: owner, token: issued.token, secret: issued.secret}
  end

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
    method
    |> conn(path, encoded(body))
    |> put_req_header("authorization", "Bearer " <> context.secret)
    |> put_req_header("content-type", "application/json")
    |> merge_req_headers(headers)
    |> Wardrik.HTTP.call(Wardrik.HTTP.init(wardrik: context.wardrik))
  end

  def body(conn), do: JSON.decode!(conn.resp_body)

  defp encoded(nil), do: ""
  defp encoded(body) when is_binary(body), do: body
  defp encoded(body), do: JSON.encode!(body)
end

defmodule Wardrik.Test.HTTP.Channel do
  @moduledoc "A channel that answers each request with where it was sent, its body, and its signature."
  @behaviour Wardrik.Channel

  @impl Wardrik.Channel
  def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> nil end]}}

  @impl Wardrik.Channel
  def request(_opts, %{path: path, body: body, headers: headers}) do
    %{
      status: 200,
      headers: %{"content-type" => "text/plain"},
      body: "#{path} #{body} #{headers["x-slack-signature"]}"
    }
  end
end
