defmodule Wardrik.Chat.Prompts do
  @moduledoc """
  Says which prompts to suggest when a member starts a conversation with the app, such as in
  Slack's Messages tab. It's asked each time, so the prompts can follow your app's data.

      slack: {WardrikSlack, ..., prompts: {MyApp.ChatPrompts, []}}

      defmodule MyApp.ChatPrompts do
        @behaviour Wardrik.Chat.Prompts

        @impl true
        def suggest(%Wardrik.Chat.Prompts.Request{} = request, _opts) do
          case MyApp.Accounts.by_chat(request.channel, request.workspace, request.member) do
            %MyApp.User{plan: :pro} -> ["Plan my week", "What's waiting on my approval?"]
            _anyone -> Wardrik.Chat.Prompts.defaults()
          end
        end
      end

  Without `:prompts`, a channel suggests `defaults/0`. `Wardrik.Chat.Prompts.Fixed` suggests a
  list of your own. A chat app may show only the first few.
  """

  alias Wardrik.Chat.Prompts.Request

  @defaults [
    "What can you do?",
    "What did you work on today?",
    "What's waiting on my approval?",
    "Check something for me every morning"
  ]

  @doc "Returns the prompts to suggest to the request's member, in the order to show them."
  @callback suggest(Request.t(), opts :: term()) :: [String.t()]

  @doc "Returns the prompts a channel suggests unless it names others."
  @spec defaults() :: [String.t()]
  def defaults, do: @defaults
end
