defmodule Wardrik.Notify.Agent do
  @options [
    agent: [type: :string, required: true, doc: "The ID of the agent it tells."],
    conversation: [
      type: :string,
      doc: "The conversation of the agent it asks in. Its main conversation unless set."
    ]
  ]

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  Tells another agent: each notice reaches it as a message, which it answers as it sees fit.

      lead: {Wardrik.Notify.Agent, agent: "agt_lead"}

  With a route to `lead` for finished turns, a worker's answers go to the lead agent, which
  decides what people hear:

      notify: [%{to: ["ops"], on: ["parked", "failed"]}, %{to: ["lead"], on: ["finished"]}]

    * The message is asked as a trigger asks, with the notifying conversation's labels, so the
      agent treats it as outside content when the notifying agent read any.
    * A notice of the agent itself is skipped.
    * `conversation` keeps the messages out of the conversation people have with the agent:

          lead: {Wardrik.Notify.Agent, agent: "agt_lead", conversation: "reports"}

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @behaviour Wardrik.Notify

  alias Wardrik.Notice
  alias Wardrik.Operations.Running

  @impl Wardrik.Notify
  def schema, do: @options

  @impl Wardrik.Notify
  def deliver(%Notice{agent: agent} = notice, opts) do
    case Keyword.fetch!(opts, :agent) do
      ^agent -> {:skip, "which is the agent itself"}
      target -> ask(notice, target, opts)
    end
  end

  defp ask(notice, target, opts) do
    wardrik = Wardrik.Instance.fetch!(opts[:wardrik])
    labels = Wardrik.Delegation.conversation_labels(wardrik, {notice.agent, notice.conversation})

    with {:ok, pid} <- Running.ensure_awake(wardrik, {target, opts[:conversation]}),
         do: WardrikCore.ask(pid, message_text(notice), metadata(labels))
  end

  defp metadata([]), do: %{}
  defp metadata(labels), do: %{labels: labels}

  defp message_text(notice), do: "From agent #{agent_label(notice)}:\n#{describe(notice)}"

  defp describe(%Notice{kind: :finished, text: text}),
    do: "It finished a turn, and answered:\n#{text}"

  defp describe(%Notice{kind: :failed, reason: reason}), do: "A turn of its failed: #{reason}"

  defp describe(%Notice{kind: :parked, calls: calls}),
    do: "It waits on a person to decide on #{Enum.map_join(calls, ", ", & &1.interrupt.name)}."

  defp agent_label(%Notice{name: nil, agent: agent}), do: agent
  defp agent_label(%Notice{name: name, agent: agent}), do: "#{name} (#{agent})"
end
