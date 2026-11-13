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

  import Wardrik.Test.Wardrik, only: [seal: 3]

  test "reads a channel's {:secret, name} from the deployment's secrets as it starts and answers",
       context do
    store_name = :"sealed store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)
    key = Wardrik.Vault.generate_key()
    start_supervised!({Wardrik.Store, store})

    vault = :"sealing #{context.test}"
    start_supervised!({Wardrik.Vault, name: vault, store: store, keys: [key]})

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Wardrik.Vault.Secret{
        principal: Wardrik.Vault.deployment(),
        name: "SIGNING",
        value: "first"
      })

    name = :"sealed #{context.test}"
    channels = [slack: {Wardrik.Test.Sealed, test: self(), signing_secret: {:secret, "SIGNING"}}]

    start_supervised!(
      {Wardrik,
       Wardrik.new(
         authorizer: {Wardrik.Test.Allow, []},
         resolver: {Wardrik.Test.Owned, name},
         name: name,
         store: store,
         vault_keys: [key],
         channels: channels
       )}
    )

    assert_receive {:started_with, "first"}

    :ok = seal(name, {"deployment", "SIGNING"}, "second")
    request = %{"channel" => "slack", "path" => "events", "body" => "{}", "headers" => %{}}

    anonymous = Wardrik.as(name, "anonymous")
    assert {:ok, %{"body" => "second"}} = Wardrik.run(anonymous, "channel.deliver", request)
  end
end
