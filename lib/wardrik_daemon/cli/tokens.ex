defmodule WardrikDaemon.CLI.Tokens do
  @moduledoc false

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Table

  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}

  @doc "Returns the commands on tokens."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "token create",
        group: "Tokens",
        arguments: "NAME",
        switches: [subject: :string, groups: :string, expires: :string],
        count: 1,
        summary: "make a token that acts as --subject, shown once",
        details: [
          "wardrik token create ana-laptop --subject user:ana --groups payments-eng --expires 30d",
          "--subject is user:ID, or agent:NAME for an agent's own, as agent:growth/triage.",
          "--groups names the groups, with commas, that bindings may give roles to. --expires",
          "takes s, m, h or d; 30d unless set.",
          "Making one needs the token kind in \"*\". Only the admin makes one for user:admin."
        ],
        run: &created/3
      },
      %Command{
        name: "token ls",
        group: "Tokens",
        summary: "the tokens, never their secrets",
        run: &tokens/3
      },
      %Command{
        name: "token revoke",
        group: "Tokens",
        arguments: "ID",
        count: 1,
        summary: "stop a token working, at once",
        run: &revoked/3
      }
    ]
  end

  defp created([name], %{subject: subject} = flags, cx) do
    with {:ok, expires_in} <- seconds(Map.get(flags, :expires, "30d")),
         {:ok, subject} <- subject(cx, subject),
         input = %{"name" => name, "subject" => subject, "expires_in" => expires_in},
         {:ok, answer} <-
           Context.call(cx, "tokens.create", Context.put(input, "groups", groups(flags[:groups]))),
         do: Context.show(cx, answer, &shown(cx, &1))
  end

  defp created([_name], _flags, _cx), do: {:error, "Give the token's --subject, as user:ana."}

  # An agent is named as the other commands name it, and the token acts as its ID.
  defp subject(cx, "agent:" <> name) do
    with {:ok, id} <- Context.agent(cx, name), do: {:ok, "agent:" <> id}
  end

  defp subject(_cx, subject), do: {:ok, subject}

  defp shown(cx, token) do
    Context.puts(cx, "Made #{token["id"]} for #{token["subject"]}. It's shown once:")
    Context.puts(cx, token["secret"])
  end

  defp groups(nil), do: nil
  defp groups(groups), do: String.split(groups, ",", trim: true)

  defp seconds(text) do
    with {amount, unit} when amount > 0 <- Integer.parse(text),
         {:ok, seconds} <- Map.fetch(@units, unit) do
      {:ok, amount * seconds}
    else
      _unread -> {:error, "--expires takes a time as 30d, 12h, 90m or 3600s."}
    end
  end

  defp tokens([], _flags, cx) do
    with {:ok, %{"tokens" => tokens} = answer} <- Context.call(cx, "tokens.list", %{}) do
      Table.show(cx, answer,
        header: ["ID", "NAME", "SUBJECT", "GROUPS", "EXPIRES"],
        rows:
          for(
            token <- Enum.sort_by(tokens, & &1["expires"]),
            do: [
              token["id"],
              token["name"],
              token["subject"],
              Enum.join(token["groups"], ","),
              token["expires"]
            ]
          ),
        empty: "No tokens."
      )
    end
  end

  defp revoked([id], _flags, cx) do
    with {:ok, answer} <- Context.call(cx, "tokens.revoke", %{"id" => id}),
         do: Context.done(cx, answer, "Revoked #{id}.")
  end
end
