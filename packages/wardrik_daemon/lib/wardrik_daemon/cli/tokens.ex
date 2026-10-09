defmodule WardrikDaemon.CLI.Tokens do
  @moduledoc """
  `wardrik token`: the HTTP API's tokens, made, listed and revoked on the
  daemon.

  `token create NAME` makes a token printed once. `--scope PREFIX` is the
  agents it reaches, `org/`, `org/@user/` or a key, `org/name` or
  `org/@user/name`, and `--all` reaches every agent. `--can ACTIONS` limits
  it to some of `read,message,decide,define,serve`. A token that can define
  agents holds them to a ceiling: `--policy NAME`, a policy `policies/`
  holds, which every agent it defines is held to ahead of its own, or
  `--unlimited`, which holds them to their own policies alone. `--for NAME`
  is the person it is issued to, whom a decision made with it is recorded
  as made by; without it, the token itself.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Grant
  alias WardrikDaemon.CLI.Command
  alias WardrikHTTP.Token

  @doc "The token commands, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "token create",
        arguments: "NAME",
        options:
          "(--scope PREFIX | --all) [--can ACTIONS] [--policy NAME | --unlimited] [--for NAME]",
        summary: "a token for the HTTP API, printed once",
        details: [
          "--scope PREFIX is the agents it reaches: org/, org/@user/, or a key, org/name or",
          "org/@user/name.",
          "--can ACTIONS limits it to some of read,message,decide,define,serve.",
          "A token that can define holds the agents it defines to --policy NAME, one of",
          "policies/, or to their own policies alone with --unlimited.",
          "--for NAME is the person it is issued to, whom its decisions are recorded as made by."
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
      %Command{name: "token list", summary: "the HTTP API's tokens", run: &list/2},
      %Command{
        name: "token revoke",
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
         {:ok, ceiling} <- ceiling(opts, can) do
      make(name, scope, can, ceiling ++ issued(opts[:for]), opts[:by])
    end
  end

  defp issued(nil), do: []
  defp issued(person), do: [for: Wardrik.Principal.new(:user, person)]

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
        {:ok, ceiling: []}

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
    policies =
      for {_path, {:ok, %WardrikPolicy{} = policy}} <- WardrikDaemon.Agents.files(),
          do: policy

    case Enum.find(policies, &(&1.name == name)) do
      nil ->
        {:error, "policies/ has no policy #{name}" <> policy_names(policies)}

      policy ->
        {:ok, ceiling: WardrikPolicy.hooks(%{policy | name: "ceiling/" <> name})}
    end
  end

  defp policy_names([]), do: ""
  defp policy_names(policies), do: "; it has " <> Enum.map_join(policies, ", ", & &1.name)

  defp make(name, scope, can, opts, by) do
    case Token.create(name, scope, can, opts) do
      {:ok, secret, token} ->
        :ok =
          Audit.record({:token_created, token.id, token.name, token.grant, token.principal}, by)

        {:ok,
         Enum.join(
           [
             secret,
             "",
             "#{token.name} (#{token.id})#{issued_to(token)} reaches #{reach(token.grant)}. " <>
               "This is the only time it is shown."
           ],
           "\n"
         )}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "The token was not made: #{inspect(reason)}"}
    end
  end

  defp list(_words, _opts) do
    rows =
      for token <- Token.list(),
          do:
            "  #{token.id}  #{token.name}#{issued_to(token)}  #{reach(token.grant)}  made #{token.created_at}"

    case rows do
      [] ->
        {:ok,
         "No tokens. Make one with: wardrik token create NAME --scope PREFIX (--policy NAME | --unlimited)"}

      [_row] ->
        {:ok, Enum.join(["1 token:" | rows], "\n")}

      rows ->
        {:ok, Enum.join(["#{length(rows)} tokens:" | rows], "\n")}
    end
  end

  defp revoke([id], opts) do
    case Token.revoke(id) do
      :ok ->
        :ok = Audit.record({:token_revoked, id}, opts[:by])
        {:ok, "Revoked #{id}."}

      {:error, :not_found} ->
        {:error, "No token has the id #{id}."}
    end
  end

  defp issued_to(%Token{principal: nil}), do: ""
  defp issued_to(%Token{principal: person}), do: ", for #{Wardrik.Principal.id(person)},"

  defp reach(%Grant{scope: scope, can: can} = grant) do
    agents =
      if scope == Prefix.all(), do: "every agent", else: "the agents under #{scope}"

    agents <> actions(can) <> held(grant)
  end

  defp held(%Grant{can: can, ceiling: ceiling}) do
    cond do
      :define not in can -> ""
      ceiling == [] -> ", with no ceiling"
      true -> ", under the ceiling #{ceiling_names(ceiling)}"
    end
  end

  # The policies a ceiling is, by name, and not their budgets' hooks.
  defp ceiling_names(ceiling) do
    Enum.map_join(
      for(
        %Wardrik.Hook{module: module} = hook <- ceiling,
        module != WardrikPolicy.Budget,
        do: hook
      ),
      ", ",
      &String.replace_prefix(&1.name, "ceiling/", "")
    )
  end

  defp actions(can) do
    {names, [last]} = can |> Enum.map(&Atom.to_string/1) |> Enum.split(-1)

    cond do
      can == Grant.actions() -> ", for every action"
      names == [] -> ", to #{last}"
      true -> ", to #{Enum.join(names, ", ")} and #{last}"
    end
  end
end
