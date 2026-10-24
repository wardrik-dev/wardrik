defmodule Wardrik.Channel do
  @moduledoc """
  A chat app people reach agents through, such as Slack, as a Wardrik takes it in `:channels`, by
  a name of your own:

      channels: [slack: {WardrikSlack, token: token, signing_secret: secret}]

  Each channel runs as a child of the Wardrik, and is handed what its chat app sends to
  `POST /v1/channels/{channel}/{path}` as it came, to check by what it carries, such as a
  signature over the body. Both callbacks take the channel's options with `:wardrik`, the instance,
  and `:channel`, its name.

      {:ok, answer} = Wardrik.Channel.deliver(scope, "slack", "events", body: body, headers: headers)
  """

  use Wardrik.Operations.Functions, prefix: "channel"

  @typedoc "What the chat app sent: where in the channel, its raw body, and its headers by lowercase name."
  @type request() :: %{path: String.t(), body: String.t(), headers: %{String.t() => String.t()}}

  @typedoc "What the chat app is answered."
  @type response() :: %{
          status: pos_integer(),
          headers: %{String.t() => String.t()},
          body: String.t()
        }

  @doc "Returns what the channel runs."
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc "Answers what the chat app sent the channel."
  @callback request(opts :: keyword(), request()) :: response()
end
