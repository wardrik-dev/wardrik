defmodule Wardrik.Catalog.Tools do
  @moduledoc """
  How `Wardrik.Catalog`'s entries are offered to an agent as tools, by two
  tool sources, each named with the agent's ID:

  | Source | Offers | On |
  | --- | --- | --- |
  | `Wardrik.Catalog.Self` | the entries on an agent, as `self_trigger_set` | the agent itself |
  | `Wardrik.Catalog.Agents` | the entries on an agent, as `agent_trigger_set`, taking the `agent` they act on, and those on the agents under a prefix, as `agents_list` | the agents of its org |

  Each tool is described by its entry's summary, and takes its input. A
  call runs the entry in a session of the calling agent's own, made with
  `Wardrik.Session.agent/1` on the host the call's run carries: the audit
  records the agent as who made a change, an agent another surface
  declares, as a file does, answers as it would there, and an agent it
  sends a message answers it back with a message of its own (see
  `Wardrik.agent_ask/4`).

  The session's grant lets it read, send messages to and define what its
  source reaches, and never more. Its ceiling is the calling agent's own
  hooks: an agent it defines is held to every policy and budget that holds
  the agent that defined it, ahead of its own, and so is never looser.

  A change is gated, so it waits on a person unless the agent's policy
  allows it by the tool's name. An answer that shows an agent's
  conversation labels the call with the labels of that agent's history, so
  content from outside that one agent read is outside content to the agent
  that reads it.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Catalog.Entry
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Resource
  alias Wardrik.Run
  alias Wardrik.Session

  @doc """
  The annotations of the tool for `entry`, or of a tool no entry offers: one
  that changes something waits on a person.
  """
  @spec annotations(Entry.t() | nil) :: map()
  def annotations(%Entry{action: action}) when action != :read, do: %{gated: true}
  def annotations(_read_or_none), do: %{}

  @doc """
  The tool for `entry`, named `:name`, taking `:schema`, which `:run`, a
  `{module, function, args}`, answers.
  """
  @spec tool(Entry.t(), name: String.t(), schema: map(), run: {module(), atom(), list()}) ::
          Wardrik.Tool.t()
  def tool(%Entry{summary: summary}, opts) do
    opts = Keyword.validate!(opts, [:name, :schema, :run])

    Wardrik.Tool.new!(
      name: Keyword.fetch!(opts, :name),
      description: summary,
      schema: Keyword.fetch!(opts, :schema),
      run: Keyword.fetch!(opts, :run)
    )
  end

  @doc """
  Runs `entry` on `subject` with `:input`, for the call `:context` is of, as
  the calling agent reaching `:reach`: the tool's answer, labelled with
  what it holds.

  The agent may read, send messages to and define the agents its reach
  covers, under its own hooks as ceiling, on the host the call's run
  carries. A read or a message is the asker's as well: where someone asked
  for the turn, it reaches only what both the agent and they may, as the
  host's `Wardrik.Grants` say of them, so an agent never reads or messages
  for someone what they could not themselves. A change is the agent's own,
  held to its ceiling and asked of a person as its policy says.
  """
  @spec run(Entry.t(), Entry.subject(),
          reach: Prefix.t(),
          input: map(),
          context: Wardrik.Tool.Context.t()
        ) :: Wardrik.Tool.answer()
  def run(%Entry{} = entry, subject, opts) do
    opts = Keyword.validate!(opts, [:reach, :input, :context])

    with {:ok, session} <- session(entry, subject, opts),
         {:ok, output, labels} <- entry.run.(session, subject, Keyword.fetch!(opts, :input)) do
      {:ok, output, labels: labels}
    else
      {:error, %Error{} = error} -> {:error, Resource.error(error)}
    end
  end

  defp session(%Entry{action: action}, subject, opts) do
    %Wardrik.Tool.Context{run: run, sender: sender} = Keyword.fetch!(opts, :context)
    {:ok, own} = Grant.new(Keyword.fetch!(opts, :reach), [:read, :message, :define], run.hooks)

    with {:ok, grant} <- asked(own, sender, subject, action, run.host),
         do: {:ok, Session.agent(id: Run.agent_id(run), grant: grant, host: run.host)}
  end

  # A turn nobody asked for is the agent's own.
  defp asked(own, nil, _subject, _action, _host), do: {:ok, own}

  defp asked(own, sender, subject, action, host) when action in [:read, :message] do
    with {:ok, %Caller{grant: theirs}} <- Host.caller(host, principal: sender, subject: subject) do
      case Grant.within(own, theirs) do
        {:ok, grant} -> {:ok, grant}
        :error -> {:error, Error.new(:forbidden, "Whoever asked may not #{action} #{subject}.")}
      end
    end
  end

  defp asked(own, _sender, _subject, _action, _host), do: {:ok, own}
end
