defmodule Wardrik.Catalog.Tools do
  @moduledoc """
  How `Wardrik.Catalog`'s entries are offered to an agent as tools, by two
  tool sources, each named with the agent's ID:

  | Source | Offers | On |
  | --- | --- | --- |
  | `Wardrik.Catalog.Self` | the entries on an agent, as `self_trigger_set` | the agent itself |
  | `Wardrik.Catalog.Agents` | the entries on an agent, as `agent_trigger_set`, taking the `agent` they act on, and those on the agents under a prefix, as `agents_list` | the agents of its org |

  Each tool is described by its entry's summary, and takes its input. A
  call runs the entry in the calling agent's scope, made with
  `Wardrik.Scope.agent/2` on the host the call's run carries, so an agent it
  sends a message answers it back with a message of its own (see
  `Wardrik.agent_ask/4`), and an agent another surface declares, as a file
  does, answers as it would there.

  The agent's own token is the `:agent` principal of its ID, holding
  `reader`, `messenger` and `definer` on what its source reaches, and never
  more. A change runs with that token, and the audit records the agent as
  who made it. An agent it defines is held to the calling agent's own
  hooks, every policy and budget that holds it, ahead of its own, and so is
  never looser. A read or a message is the asker's as
  well: it runs with the token the host's `Wardrik.Issuer` issues whoever
  asked for the turn, assumed by the agent and narrowed to what its own
  allows, so an agent never reads or messages for someone what they could
  not themselves. A turn nobody asked for, as a trigger's, acts with the
  agent's own.

  A change is gated, so it waits on a person unless the agent's policy
  allows it by the tool's name. An answer that shows an agent's
  conversation labels the call with the labels of that agent's history, so
  content from outside that one agent read is outside content to the agent
  that reads it.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Catalog.Entry
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.JSON
  alias Wardrik.Principal
  alias Wardrik.Role
  alias Wardrik.Run
  alias Wardrik.Scope
  alias Wardrik.Token

  @reads Role.actions(:reader)
  @changes Role.actions(:definer)

  @doc """
  The annotations of the tool for `entry`, or of a tool no entry offers: one
  that changes something waits on a person.
  """
  @spec annotations(Entry.t() | nil) :: map()
  def annotations(%Entry{name: name}) when name not in @reads, do: %{gated: true}
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
  what it holds. See above for the token it runs with.
  """
  @spec run(Entry.t(), Entry.subject(),
          reach: Prefix.t(),
          input: map(),
          context: Wardrik.Tool.Context.t()
        ) :: Wardrik.Tool.answer()
  def run(%Entry{} = entry, subject, opts) do
    opts = Keyword.validate!(opts, [:reach, :input, :context])
    %Wardrik.Tool.Context{run: run, sender: sender} = context = Keyword.fetch!(opts, :context)
    id = Run.agent_id(run)

    own = %Token{
      principal: Principal.new(:agent, to_string(id)),
      scope: [Role.bind([:reader, :messenger, :definer], Keyword.fetch!(opts, :reach))]
    }

    scope = Scope.agent(Scope.new(run.host, token(entry, own, sender, run.host)), id)

    case entry.run.(scope, subject, Keyword.fetch!(opts, :input), context) do
      {:ok, output, labels} -> {:ok, output, labels: labels}
      {:error, %Error{} = error} -> {:error, JSON.error(error)}
    end
  end

  defp token(%Entry{name: name}, own, _sender, _host) when name in @changes, do: own
  defp token(_entry, own, nil, _host), do: own

  defp token(_entry, own, sender, host) do
    host
    |> Host.issuer()
    |> Wardrik.Issuer.issue(sender, [])
    |> Token.assume(own.principal, scope: own.scope)
  end
end
