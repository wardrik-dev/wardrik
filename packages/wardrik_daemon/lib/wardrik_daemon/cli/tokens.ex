defmodule WardrikDaemon.CLI.Tokens do
  @moduledoc """
  `wardrik token`: the HTTP API's tokens, made, listed and revoked on the
  daemon, as `Wardrik.Operations.CreateToken`, `ListTokens` and `RevokeToken`.
  They are made from a shell on the server alone, never over the API.

  `token create NAME` makes a token printed once. `--scope PREFIX` is the
  agents it reaches: `org/`, the org's own, none of its users'; `org/@user/`,
  a user's; `org/*`, the org and every one of its users'; or a key,
  `org/name` or `org/@user/name`. `--all` reaches every agent. `--can ACTIONS` limits
  it to some of `read,message,decide,define,serve`. A token that can define
  agents holds them to a ceiling: `--policy NAME`, a policy `policies/`
  holds, which every agent it defines is held to ahead of its own, or
  `--unlimited`, which holds them to their own policies alone. `--for NAME`
  is the person it is issued to, whom a decision made with it is recorded
  as made by; without it, the token itself. A scope naming a person's agents
  names theirs.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Command, as: Operation
  alias Wardrik.Grant
  alias Wardrik.Operations.CreateToken
  alias Wardrik.Operations.ListTokens
  alias Wardrik.Operations.RevokeToken
  alias Wardrik.Query
  alias WardrikDaemon.CLI.Command

  @doc "The token commands, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "token create",
        group: "Tokens and secrets",
        arguments: "NAME",
        options:
          "(--scope PREFIX | --all) [--can ACTIONS] [--policy NAME | --unlimited] [--for NAME]",
        summary: "a token for the HTTP API, printed once",
        details: [
          "--scope PREFIX is the agents it reaches: org/ (the org's own), org/@user/ (a user's),",
          "org/* (the org and all its users'), or a key, org/name or org/@user/name.",
          "--can ACTIONS limits it to some of read,message,decide,define,serve.",
          "A token that can define holds the agents it defines to --policy NAME, one of",
          "policies/, or to their own policies alone with --unlimited.",
          "--for NAME is the person it is issued to, whom its decisions are recorded as made by;",
          "a scope naming a person's agents names theirs."
        ],
        switches: [
          scope: :string,
          all: :boolean,
          can: :string,
          policy: :string,
          unlimited: :boolean,
          for: :string
        ],
        count: {1, 1},
        run: &create/2
      },
      %Command{
        name: "token list",
        group: "Tokens and secrets",
        summary: "the HTTP API's tokens",
        run: &list/2
      },
      %Command{
        name: "token revoke",
        group: "Tokens and secrets",
        arguments: "ID",
        summary: "stop a token working",
        count: {1, 1},
        run: &revoke/2
      }
    ]
  end

  defp create([name], opts) do
    can = if opts[:can], do: String.split(opts[:can], ",", trim: true), else: Grant.actions()

    with {:ok, scope} <- scope(opts),
         {:ok, ceiling} <- ceiling(opts, can),
         {:ok, grant} <- Grant.new(scope, can, ceiling),
         {:created, %{"secret" => secret, "token" => token}} <-
           Operation.run(
             %CreateToken{name: name, grant: grant, for: issued(opts[:for])},
             opts[:caller]
           ) do
      {:ok,
       Enum.join(
         [
           secret,
           "",
           "#{token["name"]} (#{token["id"]})#{issued_to(token)} reaches #{reach(token)}. " <>
             "This is the only time it is shown."
         ],
         "\n"
       )}
    end
  end

  defp issued(nil), do: nil
  defp issued(person), do: Wardrik.Principal.new(:user, person)

  # One of --scope and --all.
  defp scope(opts) do
    case {opts[:scope], opts[:all]} do
      {scope, nil} when is_binary(scope) -> Prefix.parse(scope)
      {nil, true} -> {:ok, Prefix.all()}
      _neither_or_both -> {:error, :usage}
    end
  end

  # What a token that can define holds its agents to: a policy of policies/,
  # or, said outright, nothing but their own.
  defp ceiling(opts, can) do
    defines? = Enum.any?(can, &(&1 in [:define, "define"]))

    case {opts[:policy], opts[:unlimited]} do
      {nil, true} ->
        {:ok, []}

      {name, nil} when is_binary(name) and defines? ->
        policy_ceiling(name)

      {name, nil} when is_binary(name) ->
        {:error, "--policy holds the agents a token defines, and this one cannot define"}

      {nil, nil} when defines? ->
        {:error,
         "A token that can define agents holds them to a policy: add --policy NAME, " <>
           "one of policies/, or --unlimited to hold them to their own policies alone"}

      {nil, nil} ->
        {:ok, []}

      _both ->
        {:error, :usage}
    end
  end

  defp policy_ceiling(name) do
    with :error <- WardrikDaemon.Agents.ceiling(WardrikDaemon.Host.agents(), name) do
      policies =
        for {_path, {:ok, %WardrikPolicy{} = policy}} <-
              WardrikDaemon.Agents.files(WardrikDaemon.Host.agents()),
            do: policy

      {:error, "policies/ has no policy #{name}" <> policy_names(policies)}
    end
  end

  defp policy_names([]), do: ""
  defp policy_names(policies), do: "; it has " <> Enum.map_join(policies, ", ", & &1.name)

  defp list(_words, opts) do
    with {:ok, %{"tokens" => tokens}} <- Query.run(%ListTokens{}, opts[:caller]),
         do: {:ok, listed(tokens)}
  end

  defp listed(tokens) do
    rows =
      for token <- tokens,
          do:
            "  #{token["id"]}  #{token["name"]}#{issued_to(token)}  #{reach(token)}  made #{token["created_at"]}"

    case rows do
      [] ->
        "No tokens. Make one with: wardrik token create NAME --scope PREFIX (--policy NAME | --unlimited)"

      [_row] ->
        Enum.join(["1 token:" | rows], "\n")

      rows ->
        Enum.join(["#{length(rows)} tokens:" | rows], "\n")
    end
  end

  defp revoke([id], opts) do
    with {:ok, nil} <- Operation.run(%RevokeToken{id: id}, opts[:caller]),
         do: {:ok, "Revoked #{id}."}
  end

  defp issued_to(%{"for" => person}), do: ", for #{person},"
  defp issued_to(_token), do: ""

  defp reach(%{"scope" => scope, "can" => can} = token) do
    agents =
      if scope == to_string(Prefix.all()), do: "every agent", else: "the agents under #{scope}"

    agents <> actions(can) <> held(token)
  end

  defp held(%{"ceiling" => []}), do: ", with no ceiling"
  defp held(%{"ceiling" => ceiling}), do: ", under the ceiling #{ceiling_names(ceiling)}"
  defp held(_token), do: ""

  # The policies a ceiling is, by name, and not the judges and budgets each
  # holds beside its rules.
  defp ceiling_names(ceiling) do
    Enum.map_join(
      for("ceiling/" <> name <- ceiling, not String.contains?(name, "/"), do: name),
      ", ",
      & &1
    )
  end

  defp actions(can) do
    {names, [last]} = Enum.split(can, -1)

    cond do
      can == Enum.map(Grant.actions(), &Atom.to_string/1) -> ", for every action"
      names == [] -> ", to #{last}"
      true -> ", to #{Enum.join(names, ", ")} and #{last}"
    end
  end
end
