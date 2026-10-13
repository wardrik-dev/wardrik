defmodule WardrikTrigger.Webhook.Verifier do
  @moduledoc """
  How a webhook trigger tells that a request is the sender's, which the
  trigger names as `verify`:

      webhook:
        secret: ${PAYMENTS_HOOK_SECRET}
        verify: standard

  `verify/3` checks a request against the trigger's secret, and answers the
  sender's ID for the delivery, the same each time it sends it again, and
  the kind of event it is, where the request says. This package registers
  two, under the names a trigger gives them:

    * `shared`, the default (`WardrikTrigger.Webhook.Shared`): the request
      presents the secret itself, as any sender can
    * `standard` (`WardrikTrigger.Webhook.Standard`): the request is signed
      as the Standard Webhooks spec says

  A host that needs a service's own signature checked registers a module of
  its own in its application's environment, and a trigger names it:

      def application,
        do: [env: [wardrik_trigger_verifiers: [acme_pay: MyApp.AcmePaySignature]]]
  """

  @typedoc "What a request that verifies says of itself."
  @type delivery() :: %{id: String.t(), event: String.t() | nil}

  @doc """
  Checks the request with `headers`, names in lower case, and `body`,
  against `secret`: its delivery, or why it is not the sender's.
  """
  @callback verify(headers :: [{String.t(), String.t()}], body :: binary(), secret :: String.t()) ::
              {:ok, delivery()} | {:error, String.t()}

  @doc "Every verifier the loaded applications name, by its name."
  @spec all() :: %{String.t() => module()}
  def all do
    for {app, _description, _version} <- Application.loaded_applications(),
        {name, module} <- Application.get_env(app, :wardrik_trigger_verifiers, []),
        into: %{},
        do: {to_string(name), module}
  end

  @doc "The value of the header `name` in `headers`, or `nil`."
  @spec header([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  @doc "The HMAC-SHA256 of `content` with `key`."
  @spec hmac(binary(), binary()) :: binary()
  def hmac(key, content), do: :crypto.mac(:hmac, :sha256, key, content)

  @doc "Whether `given` and `expected` are the same, taking as long either way."
  @spec same?(binary(), binary()) :: boolean()
  def same?(given, expected),
    do: byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)
end
