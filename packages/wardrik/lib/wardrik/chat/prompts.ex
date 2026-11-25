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

  ## Next steps

  A reply can also include questions the person might ask next. In Slack they're buttons under
  the reply in a channel, or the Messages tab's suggested prompts in a direct message. Your own
  `Wardrik.Middleware` chooses them and passes them to `suggest_next/2`. The chat guide has an
  example.
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

  @doc """
  Suggests `prompts` as questions to show with the reply of the current run. Call it from a
  `Wardrik.Middleware`, passing the middleware's `context`. If a run calls it more than once, the
  reply shows the latest list.

      Wardrik.Chat.Prompts.suggest_next(context, ["Draft the email", "Show last week's numbers"])

  Each call is recorded as a `wardrik.prompts.suggested` event in the conversation's log.
  """
  @spec suggest_next(Wardrik.Context.t(), [String.t()]) :: :ok
  def suggest_next(%Wardrik.Context{} = context, prompts) when is_list(prompts),
    do:
      WardrikCore.Event.emit(context, [:wardrik, :prompts, :suggested], %{}, %{
        agent_id: context.agent_id,
        span: context.span,
        prompts: prompts
      })
end
