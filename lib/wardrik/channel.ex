defmodule Wardrik.Channel do
  @moduledoc """
  A behaviour for chat apps, like Slack, that people reach agents through.

      channels: [slack: {WardrikSlack, token: token, signing_secret: secret}]

  Requests to `POST /v1/channels/{channel}/{path}` reach `c:request/2` unchanged, so the channel
  can check their signature. To deliver one yourself:

      {:ok, answer} = Wardrik.Channel.deliver(scope,
        channel: "slack",
        path: "events",
        body: body,
        headers: headers
      )

  Every callback's options also hold:

    * `:wardrik` - the instance the channel runs under.
    * `:channel` - the channel's name.
    * `:store` - Wardrik's store. Prefix your keys with your package's name.
  """

  use Wardrik.Operations.Functions, prefix: "channel"

  @typedoc "A request from the chat app. `headers` are keyed by lowercase name."
  @type request() :: %{path: String.t(), body: String.t(), headers: %{String.t() => String.t()}}

  @typedoc "The response sent back to the chat app."
  @type response() :: %{
          status: pos_integer(),
          headers: %{String.t() => String.t()},
          body: String.t()
        }

  @doc "Returns the child spec the channel runs as."
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc "Handles a request from the chat app and returns the response."
  @callback request(request(), opts :: keyword()) :: response()

  @doc """
  Posts a `Wardrik.Channel.Notification`, or returns `{:skip, reason}`. Optional.
  """
  @callback notify(Wardrik.Channel.Notification.t(), opts :: keyword()) ::
              :ok | {:skip, String.t()} | {:error, term()}

  @optional_callbacks notify: 2
end
