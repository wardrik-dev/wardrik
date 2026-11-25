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

  A run can suggest what to ask next, shown with its reply: as the Messages tab's prompts in
  Slack's agent experience, or as buttons under the reply in a channel. Suggest them from your
  own `Wardrik.Middleware` with `suggest_next/2`. See the chat guide for an example.
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
  Suggests `prompts` as next steps for the reply of the run `context` belongs to. The last
  suggestion before the reply is shown with it. Call it from a `Wardrik.Middleware`.

      Wardrik.Chat.Prompts.suggest_next(context, ["Draft the email", "Show last week's numbers"])

  It's kept as `wardrik.prompts.suggested` in the conversation's log.
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
