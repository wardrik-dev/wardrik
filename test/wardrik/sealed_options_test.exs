defmodule Wardrik.Test.Sealed do
  @moduledoc "A channel that tells the test the signing secret it started and answers with."
  @behaviour Wardrik.Channel

  @impl Wardrik.Channel
  def child_spec(opts),
    do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> started(opts) end]}}

  @impl Wardrik.Channel
  def request(_request, opts), do: %{status: 200, headers: %{}, body: opts[:signing_secret]}

  defp started(opts), do: send(opts[:test], {:started_with, opts[:signing_secret]})
end

defmodule Wardrik.SealedOptionsTest do
  use ExUnit.Case, async: false

  test "reads a channel's {:secret, name} from the deployment's secrets as it starts and answers",
       context do
    store = Wardrik.Test.Store.new(:"sealed store #{context.test}")
    key = WardrikVault.generate_key()
    start_supervised!({WardrikStore, store})
    start_supervised!({WardrikVault, name: :"sealing #{context.test}", store: store, keys: [key]})

    {:ok, _vsn} =
      WardrikVault.put(:"sealing #{context.test}", WardrikVault.deployment(), "SIGNING", "first")

    name = :"sealed #{context.test}"
    channels = [slack: {Wardrik.Test.Sealed, test: self(), signing_secret: {:secret, "SIGNING"}}]

    start_supervised!(
      {Wardrik, Wardrik.new(name: name, store: store, keys: [key], channels: channels)}
    )

    assert_receive {:started_with, "first"}

    :ok = Wardrik.put_secret(name, "deployment", "SIGNING", "second")
    request = %{"channel" => "slack", "path" => "events", "body" => "{}", "headers" => %{}}

    assert {:ok, %{"body" => "second"}} =
             Wardrik.run(Wardrik.as(name, "anonymous"), "channel.deliver", request)
  end
end
