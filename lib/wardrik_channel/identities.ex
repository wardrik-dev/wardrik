defmodule WardrikChannel.Identities do
  @moduledoc """
  Says who each chat member is in your app.

  Pass an implementation to a channel as `identities: {module, opts}`. Every channel needs one.

      slack: {WardrikSlack, token: token, signing_secret: secret, identities: {MyApp.ChatMembers, []}}

      defmodule MyApp.ChatMembers do
        @behaviour WardrikChannel.Identities

        @impl true
        def identify(%WardrikChannel.Identities.Request{} = request, _opts) do
          case MyApp.Accounts.by_chat(request.channel, request.workspace, request.member) do
            %MyApp.User{} = user -> {:ok, %WardrikCore.Principal{id: user.id}}
            nil -> {:error, "Link your Slack account in MyApp first."}
          end
        end
      end

  A member acts as the principal it returns, with the channel as actor, `{:channel, name}`. Your
  authorizer decides what they may ask, read and decide. A member it returns an error for can't
  ask or decide, and is told the error.
  """

  alias WardrikChannel.Identities.Request

  @doc "Returns who the request's member is, or what to tell them if they may not act."
  @callback identify(Request.t(), opts :: term()) ::
              {:ok, WardrikCore.Principal.t()} | {:error, String.t()}
end
