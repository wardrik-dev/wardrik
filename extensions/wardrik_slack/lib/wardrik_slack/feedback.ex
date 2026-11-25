defmodule WardrikSlack.Feedback do
  @moduledoc """
  Puts thumbs up and down buttons under a reply, and records each press with
  `Wardrik.Chat.rate/2`.

  Each button carries the reply's agent, conversation and run. Only the member who pressed is
  told it was noted; the agent isn't.
  """

  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Rating
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages

  @action "wardrik_feedback"

  @doc "Returns the block of feedback buttons for `outbound`'s reply."
  @spec block(Outbound.t()) :: map()
  def block(%Outbound{agent: agent, conversation: conversation, run: run}) do
    button = fn rating, label ->
      value = JSON.encode!(%{g: agent, c: conversation, r: run, v: rating})
      %{text: Blocks.plain(label), accessibility_label: label, value: value}
    end

    %{
      type: "context_actions",
      elements: [
        %{
          type: "feedback_buttons",
          action_id: @action,
          positive_button: button.("positive", "Good answer"),
          negative_button: button.("negative", "Bad answer")
        }
      ]
    }
  end

  @doc "Handles a press of a feedback button. Returns `:ignored` for anything else."
  @spec answer(Workspace.t(), map()) :: :ok | :ignored
  def answer(
        workspace,
        %{"actions" => [%{"action_id" => @action, "value" => value} | _rest]} = payload
      ) do
    case JSON.decode(value) do
      {:ok, %{"g" => agent, "r" => run, "v" => rated} = button}
      when rated in ["positive", "negative"] ->
        rating = %Rating{
          member: Messages.sender(workspace, get_in(payload, ["user", "id"])),
          agent: agent,
          conversation: button["c"],
          run: run,
          rating: rating(rated)
        }

        said = describe_rating(Wardrik.Chat.rate(workspace, rating))

        API.respond(
          payload["response_url"],
          Blocks.ephemeral(said),
          API.req_options(workspace.channel)
        )

      _unreadable ->
        :ignored
    end
  end

  def answer(_workspace, _payload), do: :ignored

  defp rating("positive"), do: :positive
  defp rating("negative"), do: :negative

  defp describe_rating(:ok), do: "Thanks, noted."
  defp describe_rating({:error, message}), do: message
end
