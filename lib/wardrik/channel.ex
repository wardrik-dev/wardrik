defmodule Wardrik.Channel do
  @moduledoc """
  A chat app people reach agents through, such as Slack, as a Wardrik takes it in `:channels`, by
  a name of your own:

      channels: [slack: {WardrikSlack, token: token, signing_secret: secret}]

  Each channel runs as a child of the Wardrik, and is handed what its chat app sends to
  `POST /v1/channels/{channel}/{path}` as it came, to check by what it carries, such as a
  signature over the body. Both callbacks take the channel's options with `:wardrik`, the instance,
  `:channel`, its name, and `:store`, the Wardrik's store, to scope by the package's name.

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

  @doc """
  Returns the channel the Wardrik `instance` runs as `name`: its module, and the options its
  callbacks take. Returns `:error` where it runs none by that name.
  """
  @spec fetch(atom(), String.t()) :: {:ok, {module(), keyword()}} | :error
  def fetch(instance, name) do
    wardrik = Wardrik.Instance.fetch!(instance)

    with {:ok, {module, opts}} <- Map.fetch(wardrik.channels, name),
         do: {:ok, {module, Wardrik.Operations.Channels.options(wardrik, name, opts)}}
  end

  @doc "Returns what the channel runs."
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc "Answers what the chat app sent the channel."
  @callback request(opts :: keyword(), request()) :: response()

  @doc """
  Posts `notice` in `room`, asking `approvers` by name, as the channel names people, about the calls
  a parked turn waits on. Returns `{:skip, why}` where there's nowhere to post it. A channel that
  doesn't define it posts no notices; see `Wardrik.Notify`.
  """
  @callback notify(
              opts :: keyword(),
              room :: String.t(),
              Wardrik.Notice.t(),
              approvers :: [String.t()]
            ) ::
              :ok | {:skip, String.t()} | {:error, term()}

  @optional_callbacks notify: 4
end
