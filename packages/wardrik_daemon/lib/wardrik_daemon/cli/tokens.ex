defmodule WardrikDaemon.CLI.Tokens do
  @moduledoc """
  `wardrik token`: the HTTP API's tokens, made, listed and revoked on the
  daemon, as `Wardrik.tokens_create/4`, `tokens_list/1` and `tokens_revoke/2`
  do over the API at `/v1/tokens`. A token acts for whoever made it.

  `token create NAME` makes a token printed once. It allows its roles, each a
  named set of actions (see `Wardrik.Role`), on the agents under its scope:
  `--scope PREFIX` is `org/`, the org's own, none of its users'; `org/@user/`,
  a user's; `org/*`, the org and every one of its users'; or a key,
  `org/name` or `org/@user/name`. `--all` is every agent. `--policy NAME`, a
  policy `policies/` holds, is its policy: every agent it defines runs under
  it, ahead of its own. `--expires` is how long it works, `30d` or `12h`;
  `config.yaml`'s `tokens.expires.api` where left out.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.JSON
  alias Wardrik.Role
  alias WardrikDaemon.CLI.Command

  @roles ~w(reader messenger approver definer worker owner)a

  @doc "The token commands, for `WardrikDaemon.CLI.commands/0`."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "token create",
        group: "Tokens and secrets",
        arguments: "NAME",
        options: "(--scope PREFIX | --all) --role ROLES [--policy NAME] [--expires 30d]",
        summary: "a token for the HTTP API, printed once",
        details: [
          "--scope PREFIX is the agents it reaches: org/ (the org's own), org/@user/ (a user's),",
          "org/* (the org and all its users'), or a key, org/name or org/@user/name.",
          "--role ROLES is what it may do there, some of #{Enum.join(@roles, ",")}.",
          "--policy NAME, one of policies/, holds every agent it defines.",
          "--expires is how long it works, as 30d or 12h; tokens.expires.api by default.",
          "It acts for whoever made it."
        ],
        switches: [
          scope: :string,
          all: :boolean,
          role: :string,
          policy: :string,
          expires: :string
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
    with {:ok, scope} <- scope(opts),
         {:ok, roles} <- roles(opts[:role]),
         {:ok, policy} <- policy(opts[:policy]),
         {:ok, expires} <- expires(opts[:expires]),
         {:ok, issued} <-
           Wardrik.tokens_create(
             opts[:as],
             name,
             [Role.bind(roles, scope)],
             policy ++ expires
           ) do
      token = JSON.token(issued)

      {:ok,
       Enum.join(
         [
           issued.secret,
           "",
           "#{token["name"]} (#{token["id"]}) allows #{allows(token)}. " <>
             "This is the only time it is shown."
         ],
         "\n"
       )}
    end
  end

  # One of --scope and --all.
  defp scope(opts) do
    case {opts[:scope], opts[:all]} do
      {scope, nil} when is_binary(scope) -> scope |> Prefix.parse() |> declared()
      {nil, true} -> {:ok, Prefix.all()}
      _neither_or_both -> {:error, :usage}
    end
  end

  defp declared({:ok, scope}) do
    case Prefix.org(scope) do
      nil -> {:ok, scope}
      org -> declared(WardrikDaemon.Config.declared(WardrikDaemon.Host.config(), org), scope)
    end
  end

  defp declared(error), do: error

  defp declared(:ok, scope), do: {:ok, scope}
  defp declared({:error, message}, _scope), do: {:error, "--scope: " <> message}

  defp roles(nil), do: {:error, :usage}

  defp roles(names) do
    case Role.parse(String.split(names, ",", trim: true)) do
      {:ok, []} -> {:error, :usage}
      {:ok, roles} -> {:ok, roles}
      {:error, message} -> {:error, "--role: " <> message}
    end
  end

  defp policy(nil), do: {:ok, []}

  defp policy(name) do
    names =
      for {_path, {:ok, %WardrikPolicy{name: held}}} <-
            WardrikDaemon.Agents.files(WardrikDaemon.Host.agents()),
          do: held

    if name in names,
      do: {:ok, [policy: name]},
      else: {:error, "policies/ has no policy #{name}" <> policy_names(names)}
  end

  defp policy_names([]), do: ""
  defp policy_names(names), do: "; it has #{Enum.join(names, ", ")}"

  defp expires(nil), do: {:ok, []}

  defp expires(text) do
    case WardrikDaemon.Config.seconds(text) do
      {:ok, seconds} -> {:ok, [expires_in: seconds]}
      :error -> {:error, "--expires is how long it works, as 30d, 12h, 30m or 45s"}
    end
  end

  defp list(_words, opts) do
    with {:ok, tokens} <- Wardrik.tokens_list(opts[:as]),
         do: {:ok, listed(Enum.map(tokens, &JSON.token/1))}
  end

  defp listed(tokens) do
    rows =
      for token <- tokens,
          do: "  #{token["id"]}  #{token["name"]}  #{allows(token)}  made #{token["created_at"]}"

    case rows do
      [] ->
        "No tokens. Make one with: wardrik token create NAME --scope PREFIX --role ROLES"

      [_row] ->
        Enum.join(["1 token:" | rows], "\n")

      rows ->
        Enum.join(["#{length(rows)} tokens:" | rows], "\n")
    end
  end

  defp revoke([id], opts) do
    with {:ok, _token} <- Wardrik.tokens_revoke(opts[:as], id),
         do: {:ok, "Revoked #{id}."}
  end

  # What a token allows, on what, under which policy, until when.
  defp allows(token) do
    Enum.map_join(token["statements"], "; ", &statement/1) <>
      held(token["policy"]) <> until(token["expires"])
  end

  defp statement(%{"actions" => actions, "resources" => resources}),
    do: "#{named(actions)} on " <> Enum.map_join(resources, ", ", &agents/1)

  defp agents(""), do: "every agent"
  defp agents(prefix), do: prefix

  # The roles whose actions these are, where they are, else the actions.
  defp named(actions) do
    roles = for role <- @roles, Enum.all?(Role.actions(role), &(&1 in actions)), do: role

    if roles != [] and actions -- Enum.flat_map(roles, &Role.actions/1) == [],
      do: Enum.join(roles, ", "),
      else: Enum.join(actions, ", ")
  end

  defp held(nil), do: ""
  defp held(policy), do: ", under the policy #{policy}"

  defp until(nil), do: ""
  defp until(expires), do: ", until #{expires}"
end
