defmodule WardrikSlack.NextSteps do
  @moduledoc """
  Shows the questions a run suggested with its reply. See `Wardrik.Chat.Prompts.suggest_next/2`.

    * In a direct message, such as on the Messages tab, they're set as the suggested prompts.
    * In a channel, they're buttons under the reply. When a member presses one, the thread gets a
      message saying what they asked, and the agent gets the question as if they had typed it.

  Slack shows at most four.
  """

  alias Wardrik.Chat.Inbound
  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages

  require Logger

  @shown 4
  @action "wardrik_prompt"
  @block "wardrik_prompts"
  @label 75

  @doc "Returns the buttons to show under a reply in a channel. Returns `[]` in a direct message."
  @spec blocks(Outbound.t()) :: [map()]
  def blocks(%Outbound{prompts: []}), do: []
  def blocks(%Outbound{room: "D" <> _direct}), do: []

  def blocks(%Outbound{prompts: prompts}) do
    buttons =
      prompts
      |> Enum.take(@shown)
      |> Enum.with_index()
      |> Enum.map(&button/1)

    [Blocks.actions(@block, buttons)]
  end

  defp button({prompt, index}) do
    label = Blocks.clip(prompt, @label)
    Blocks.button(label, action_id: "#{@action}:#{index}", value: prompt)
  end

  @doc """
  Sets a direct message's suggested prompts to the reply's questions. Does nothing in a channel,
  or when the reply has no questions.
  """
  @spec suggest(Workspace.t(), Outbound.t()) :: :ok
  def suggest(workspace, %Outbound{room: "D" <> _direct = room, prompts: [_ | _] = prompts}) do
    suggested = %{
      channel_id: room,
      prompts:
        prompts
        |> Enum.take(@shown)
        |> Enum.map(&%{title: &1, message: &1})
    }

    case API.post_in(workspace, "assistant.threads.setSuggestedPrompts", suggested) do
      {:ok, _set} -> :ok
      {:error, "static_prompts_configured"} -> :ok
      {:error, reason} -> Logger.warning("Slack didn't take the next steps: #{inspect(reason)}")
    end

    :ok
  end

  def suggest(_workspace, _outbound), do: :ok

  @doc "Handles a press of one of the question buttons. Returns `:ignored` for any other press."
  @spec answer(Workspace.t(), map()) :: :ok | :ignored
  def answer(
        workspace,
        %{
          "actions" => [%{"action_id" => @action <> ":" <> _index, "value" => prompt} | _rest],
          "channel" => %{"id" => room},
          "message" => %{"thread_ts" => thread} = message,
          "user" => %{"id" => user}
        } = payload
      ) do
    member = Messages.sender(workspace, user)
    said = "<@#{user}> asked: #{prompt}"

    with {:ok, %{"ts" => ts}} <-
           API.post_in(workspace, "chat.postMessage", %{
             channel: room,
             thread_ts: thread,
             text: said
           }) do
      inbound = %Inbound{
        room: room,
        thread: thread,
        id: ts,
        sender: member,
        text: prompt,
        mentioned?: true
      }

      workspace
      |> Wardrik.Chat.answer_inbound(inbound)
      |> respond(workspace, payload, message)
    end

    :ok
  end

  def answer(_workspace, _payload), do: :ignored

  defp respond({:asked, _conversation}, workspace, payload, message) do
    blocks = for block <- message["blocks"], block["block_id"] != @block, do: block
    replaced = %{replace_original: true, text: message["text"], blocks: blocks}
    API.respond(payload["response_url"], replaced, API.req_options(workspace.channel))
  end

  defp respond({:error, why}, workspace, payload, _message),
    do:
      API.respond(
        payload["response_url"],
        Blocks.ephemeral(why),
        API.req_options(workspace.channel)
      )

  defp respond(:ignored, _workspace, _payload, _message), do: :ok
end
