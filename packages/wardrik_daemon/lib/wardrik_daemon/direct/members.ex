defmodule WardrikDaemon.Direct.Members do
  @moduledoc """
  Answers each member's direct messages with an agent of their own, made from the agent `direct`
  names on their first one. It's the daemon's `Wardrik.Chat.Direct` for `per: member`.

      channels:
        slack: {type: slack, ..., direct: {agent: assistant, per: member}}

    * Ana's agent is `assistant.ana`, owned by `acme/@ana`, in her org.
    * It's defined as `assistant` is, without its triggers or notices. A reload that defines
      `assistant` defines it again, so a change to `assistant.md` reaches every member's agent.
    * If `assistant.md` is removed, members' agents keep their last definition.
    * A member who isn't a person, as `user:admin`, is answered by `assistant` itself.
  """

  @behaviour Wardrik.Chat.Direct

  alias Wardrik.Error
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Agents
  alias WardrikDaemon.CreateAgent
  alias WardrikDaemon.Direct
  alias WardrikDaemon.Owners

  # A member's agent runs when they write to it, and tells them, not the template's audience.
  @kept_back ["triggers", "notify"]

  @impl Wardrik.Chat.Direct
  def agent(%Wardrik.Chat.Direct.Request{principal: %{id: owner}} = request, opts) do
    case Owners.person(owner) do
      nil -> Direct.agent(request, opts)
      person -> find_agent(opts, owner, Keyword.fetch!(opts, :name) <> "." <> person)
    end
  end

  defp find_agent(opts, owner, name) do
    case AgentRecords.fetch_by_name(opts[:store], Owners.org(owner), name) do
      {:ok, %{owner: ^owner, id: id}} -> {:ok, id}
      {:ok, _other} -> {:error, "Another agent is called #{name}, so you can't have yours."}
      :error -> create_agent(opts, owner, name)
    end
  end

  defp create_agent(opts, owner, name) do
    daemon = %{wardrik: opts[:wardrik], store: opts[:store]}
    scope = Agents.scope(wardrik: opts[:wardrik])

    with {:ok, template} <- Direct.fetch_agent(opts),
         {:ok, %{"definition" => definition}} <-
           Wardrik.run(scope, "agent.definition", %{"agent" => template}),
         {:ok, record} <-
           CreateAgent.create(daemon, scope, {owner, copy(definition, name)}, from: template) do
      {:ok, record.id}
    else
      # Two first messages at once: the other made it.
      {:error, %Error{type: :conflict}} -> find_agent(opts, owner, name)
      {:error, %Error{message: message}} -> {:error, message}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Defines each agent made from the agent `template` again, from its definition now. Returns what
  went wrong, for the log.

    * `:wardrik` - the Wardrik.
    * `:store` - where agents' records are kept.
  """
  @spec follow(keyword(), String.t()) :: [String.t()]
  def follow(opts, template) do
    scope = Agents.scope(opts)

    case Wardrik.run(scope, "agent.definition", %{"agent" => template}) do
      {:ok, %{"definition" => definition}} ->
        for record <- AgentRecords.list_made_from(opts[:store], template),
            not Agents.gone?(opts, record),
            problem = define_again(scope, record, definition),
            problem != :ok,
            do: problem

      {:error, _undefined} ->
        []
    end
  end

  defp define_again(scope, record, definition) do
    definition = Map.drop(definition, @kept_back)

    case Wardrik.run(scope, "agent.define", Map.put(definition, "agent", record.id)) do
      {:ok, _snapshot} -> :ok
      {:error, %Error{message: message}} -> "didn't define #{record.name} again: #{message}"
    end
  end

  defp copy(definition, name) do
    definition
    |> Map.drop(@kept_back)
    |> Map.put("name", name)
  end
end
