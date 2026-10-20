defmodule Wardrik.Thread do
  @moduledoc """
  One conversation of an agent, where one agent answers for many, such as
  a thread in a chat: the agent, and the ID it answers for.

  | Text | Resource | The thread |
  | --- | --- | --- |
  | `acme/triage/C1-1696.1234` | `acme/agent/triage/thread/C1-1696.1234` | acme's `triage`, answering for `C1-1696.1234` |
  | `acme/@jon/triage/1696.1234` | `acme/@jon/agent/triage/thread/1696.1234` | jon's `triage`, answering for `1696.1234` |

  A thread is a process of its own, a `Wardrik.AgentAddress` as its agent
  is. It holds its own log, history and queue, the calls it parks and who
  decided them, and acts as the principal its resource names. The rest it
  reads from its agent: the definition it runs on, its workspace, its
  meters, the tools it has on itself, and its name. It has no definition
  and no triggers of its own, and comes to be as it is started, as a
  channel starts one for each conversation, by `Wardrik.agent_spawn/3`, or
  by anything reaching it while its agent is defined.

      thread = Wardrik.Thread.new!(~A"acme/triage", "C1-1696.1234")
      {:ok, pid} = Wardrik.Fleet.spawn(thread, config: config)
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Segment

  @enforce_keys [:agent, :id]
  defstruct [:agent, :id]

  @type t() :: %__MODULE__{agent: AgentID.t(), id: String.t()}

  @doc """
  The thread of `agent` answering for `id`, written down through
  `Wardrik.AgentID.Segment`.
  """
  @spec new(AgentID.t(), term()) :: {:ok, t()} | {:error, String.t()}
  def new(%AgentID{} = agent, id) do
    segment = Segment.to_segment(id)

    if AgentID.segment?(segment),
      do: {:ok, %__MODULE__{agent: agent, id: segment}},
      else:
        {:error,
         "a thread's ID is #{inspect(segment)} from #{inspect(id)}, which is not a segment; " <>
           "a segment holds no / or whitespace, nor *, ? or :, and does not begin with @ or _"}
  end

  @doc "`new/2`, raising `ArgumentError` where it answers an error."
  @spec new!(AgentID.t(), term()) :: t()
  def new!(agent, id), do: ok!(new(agent, id))

  @doc """
  The thread `text` writes, as `to_string/1` writes one: its agent's ID,
  then its own.

      Wardrik.Thread.parse("acme/triage/C1-1696.1234")
      #=> {:ok, #Wardrik.Thread<acme/triage/C1-1696.1234>}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    {agent, [id]} = text |> String.split("/") |> Enum.split(-1)

    with {:ok, agent} <- AgentID.parse(Enum.join(agent, "/")),
         true <- AgentID.segment?(id) do
      {:ok, %__MODULE__{agent: agent, id: id}}
    else
      _not_a_thread ->
        {:error,
         "#{text} is not a thread's ID; one is its agent's, org/name or org/@user/name, " <>
           "then its own"}
    end
  end

  @doc "`parse/1`, raising `ArgumentError` where it answers an error."
  @spec parse!(String.t()) :: t()
  def parse!(text), do: ok!(parse(text))

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: raise(ArgumentError, message)

  defimpl Wardrik.AgentAddress do
    def resource(%{agent: agent, id: id}),
      do: Wardrik.Resource.new(Wardrik.AgentID.resource(agent), thread: id)

    def agent(%{agent: agent}), do: agent
  end

  defimpl String.Chars do
    def to_string(%{agent: agent, id: id}), do: "#{agent}/#{id}"
  end

  defimpl Inspect do
    def inspect(thread, _opts), do: "#Wardrik.Thread<" <> to_string(thread) <> ">"
  end
end
