defmodule Wardrik.Notify.Judge do
  @moduledoc false

  # Asks a model whether a finished turn's answer is worth sending, with the agent's own context:
  # its keys, as the step `notify`. Its cost counts toward the agent's spending.

  alias Wardrik.Context
  alias Wardrik.Notice
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Workspace.Files

  require Logger

  @model "typesafe:jev-latest"
  @send 0.5

  @doc "Reads a route's `judge`, as the definition holds it, or `nil`."
  @spec read(map() | nil) :: Wardrik.Notify.Route.judge() | nil
  def read(nil), do: nil

  def read(%{"question" => question} = judge),
    do: %{
      question: question,
      send: Map.get(judge, "send", @send),
      model: Map.get(judge, "model", @model)
    }

  @doc """
  Returns `:send` or `:hold` for `notice`. Only a finished notice is judged. One the model can't
  judge is sent.
  """
  @spec decide(Wardrik.t(), Notice.t(), Wardrik.Notify.Route.judge() | nil) :: :send | :hold
  def decide(_wardrik, %Notice{kind: kind}, judge) when kind != :finished or is_nil(judge),
    do: :send

  def decide(wardrik, %Notice{} = notice, judge) do
    with pid when is_pid(pid) <- Running.whereis(wardrik, {notice.agent, notice.conversation}),
         context = WardrikCore.context(pid),
         {:ok, probability} <- judge(wardrik, context, notice, judge) do
      if probability >= judge.send,
        do: :send,
        else:
          hold(wardrik, context, notice, %{"probability" => probability, "send" => judge.send})
    else
      nil -> log_unjudged(notice, :not_running)
      {:park, reason, _context} -> log_unjudged(notice, {:parked, reason})
      {:error, reason} -> log_unjudged(notice, reason)
    end
  end

  defp judge(wardrik, context, notice, judge) do
    questions = %{"send" => %{type: :boolean, instructions: judge.question}}
    state = state(wardrik, notice)

    with {:ok, after_step} <-
           Context.run(context, {:step, "notify"}, &evaluate(&1, judge.model, state, questions)) do
      Wardrik.Spending.count(
        wardrik,
        context.agent_id,
        context.measurements,
        after_step.measurements
      )

      probability(after_step.response)
    end
  end

  defp evaluate(context, model, state, questions) do
    with {:ok, answers, measurements} <-
           WardrikCore.evaluate(context, model: model, state: state, questions: questions),
         do: {:ok, %{Context.add_reported(context, measurements) | response: {:ok, answers}}}
  end

  defp probability({:ok, %{"send" => %{"probability" => probability}}})
       when is_number(probability),
       do: {:ok, probability}

  defp probability(_answers), do: {:error, :no_answer}

  defp state(wardrik, notice) do
    answer = "The agent's answer, to send or hold:\n\n" <> (notice.text || "")

    case Files.read(wardrik.store,
           tree: Wardrik.Workspace.Agents.tree(notice.agent),
           path: Wardrik.Digest.path(notice.conversation)
         ) do
      {:ok, digest, _version} ->
        answer <> "\n\nIts digest of the conversation before it:\n\n" <> digest.content

      :none ->
        answer
    end
  end

  defp hold(wardrik, context, notice, data) do
    scope = Wardrik.as(wardrik, context.principal, actor: {:agent, context.agent_id})

    :ok =
      Changes.record(%{scope | wardrik: wardrik},
        type: "notice.held",
        agent: {notice.agent, notice.conversation},
        data: data
      )

    :hold
  end

  defp log_unjudged(notice, reason) do
    Logger.warning(
      "#{Running.describe({notice.agent, notice.conversation})}'s notice is sent unjudged: " <>
        inspect(reason)
    )

    :send
  end
end
