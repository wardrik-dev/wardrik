defmodule WardrikTrigger.Webhook.Scheme do
  @moduledoc """
  How a service signs the webhooks it sends, which a `webhook` trigger names:

      %{"webhook" => "github", "secret" => "${GITHUB_SIGNING_SECRET}", "prompt" => "..."}

  `verify/3` checks a request against the secret, and answers the sender's
  ID for the delivery, the same each time it sends it again, and the kind of
  event it is. A package registers a scheme under its name in its
  application's environment:

      def application,
        do: [env: [wardrik_trigger_webhooks: [stripe: MyApp.Stripe]]]

  This package registers `github` (`WardrikTrigger.Webhook.GitHub`) and
  `standard` (`WardrikTrigger.Webhook.Standard`).
  """

  @typedoc "What a request that verifies says of itself."
  @type delivery() :: %{id: String.t(), event: String.t() | nil}

  @doc """
  Checks the request with `headers`, names in lower case, and `body`,
  against `secret`: its delivery, or why it is not the sender's.
  """
  @callback verify(headers :: [{String.t(), String.t()}], body :: binary(), secret :: String.t()) ::
              {:ok, delivery()} | {:error, String.t()}

  @doc "Every scheme the loaded applications name, by its name."
  @spec all() :: %{String.t() => module()}
  def all do
    for {app, _description, _version} <- Application.loaded_applications(),
        {name, module} <- Application.get_env(app, :wardrik_trigger_webhooks, []),
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
