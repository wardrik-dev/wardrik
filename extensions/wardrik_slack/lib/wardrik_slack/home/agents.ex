defmodule WardrikSlack.Home.Agents do
  @moduledoc """
  The Home tab a channel shows unless its `:home` option names another. See `WardrikSlack.Home`.

    * Each agent the member can use in this channel, with what it's for and what it's doing.
    * Each call those agents are waiting on a person for, with a link to the thread where it can
      be approved or denied.

  Everything is read as the member, so they see only what your authorizer lets them read.
  """

  @behaviour WardrikSlack.Home

  alias Wardrik.Chat.Offer
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Home.Request

  @impl WardrikSlack.Home
  def blocks(%Request{workspace: workspace, member: member}, _opts) do
    case Workspace.member_scope(workspace, member) do
      {:ok, scope} -> page(workspace, scope, Workspace.list_offered_agents(workspace, member))
      {:error, why} -> [Blocks.section(why)]
    end
  end

  defp page(_workspace, _scope, []),
    do: [header("Agents"), Blocks.section("No agents are available to you here yet.")]

  defp page(workspace, scope, offers) do
    {:ok, conversations} = Wardrik.Agents.list(scope, agents: Enum.map(offers, & &1.agent))
    waiting = for %Wardrik.Agent{status: :parked} = parked <- conversations, do: parked

    [header("Agents") | Enum.map(offers, &describe_agent(&1, conversations))] ++
      [header("Waiting for a decision") | calls(workspace, scope, waiting)]
  end

  defp header(text), do: %{type: "header", text: Blocks.plain(text)}

  defp describe_agent(%Offer{agent: agent} = offer, conversations) do
    statuses = for %Wardrik.Agent{id: ^agent, status: status} <- conversations, do: status
    about = if offer.description, do: "\n" <> offer.description, else: ""

    Blocks.section("*#{offer.name || agent}* · #{describe_status(statuses)}#{about}")
  end

  defp describe_status(statuses) do
    waiting = Enum.count(statuses, &(&1 == :parked))

    cond do
      :running in statuses -> "Working"
      waiting == 1 -> "Waiting on 1 conversation"
      waiting > 1 -> "Waiting on #{waiting} conversations"
      :unreadable in statuses -> "Can't be read"
      true -> "Idle"
    end
  end

  defp calls(_workspace, _scope, []), do: [Blocks.section("Nothing is waiting for a decision.")]

  defp calls(workspace, scope, waiting) do
    for %Wardrik.Agent{id: agent, conversation: conversation} <- waiting,
        {:ok, %Wardrik.Agent{interrupts: interrupts}} <-
          [Wardrik.Agent.read(scope, agent, conversation: conversation)],
        link = link(workspace, conversation),
        interrupt <- interrupts,
        do: Blocks.section("`#{interrupt.name || "the model"}`  #{interrupt.message}#{link}")
  end

  # A call in an agent's own conversation is asked about in a notice, which has no thread to link.
  defp link(workspace, conversation) do
    with {:ok, room: room, thread: thread} <- Workspace.locate(workspace, conversation),
         {:ok, %{"permalink" => url}} <-
           API.read_in(workspace, "chat.getPermalink", %{channel: room, message_ts: thread}) do
      "\n<#{url}|Open the thread to decide>"
    else
      _unlinked -> ""
    end
  end
end
