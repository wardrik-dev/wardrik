defmodule WardrikDaemon.CLI.Servers do
  @moduledoc """
  The commands on the MCP servers and notify targets an owner adds, and the accounts an owner
  connects. See `WardrikDaemon.Servers` and `WardrikDaemon.NotifyTargets`.

  Each acts for the deployment's org, unless given `--org` or `--user`.
  """

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Table

  @owner [org: :string, user: :string]

  @doc "Returns the commands on MCP servers, notify targets and connections."
  @spec commands() :: [Command.t()]
  def commands do
    [
      %Command{
        name: "server ls",
        group: "MCP servers",
        switches: @owner,
        summary: "the MCP servers an owner added for their agents",
        run: &servers/3
      },
      %Command{
        name: "server add",
        group: "MCP servers",
        arguments: "NAME",
        switches:
          [url: :string, secret: :string, oauth: :boolean, scope: :keep, only: :string] ++ @owner,
        count: 1,
        summary: "add an MCP server at --url for an owner's agents",
        details: [
          "Its agents sign in with the owner's --secret NAME from the vault, with --oauth, asking",
          "for each --scope, or with nothing. --only names the tools they take, with commas.",
          "Agents reach it as NAME/* in their tools."
        ],
        run: &added/3
      },
      %Command{
        name: "server rm",
        group: "MCP servers",
        arguments: "NAME",
        switches: @owner,
        count: 1,
        summary: "remove an MCP server an owner added",
        run: &removed/3
      },
      %Command{
        name: "notify ls",
        group: "Notify targets",
        switches: @owner,
        summary: "the webhooks and rooms an owner's agents' notices reach",
        run: &targets/3
      },
      %Command{
        name: "notify add",
        group: "Notify targets",
        arguments: "NAME",
        switches: [url: :string, secret: :string] ++ @owner,
        count: 1,
        summary: "add a webhook at --url for an owner's agents' notices",
        details: [
          "--secret names the owner's secret in the vault, sealed for signing_secret, that signs",
          "each notice. Agents route to it with notify: NAME."
        ],
        run: &target_added/3
      },
      %Command{
        name: "notify rm",
        group: "Notify targets",
        arguments: "NAME",
        switches: @owner,
        count: 1,
        summary: "remove a webhook an owner added",
        run: &target_removed/3
      },
      %Command{
        name: "connection ls",
        group: "Connections",
        switches: @owner,
        summary: "the accounts an owner is offered, and which they hold",
        run: &connections/3
      },
      %Command{
        name: "connection connect",
        group: "Connections",
        arguments: "PROVIDER",
        switches: @owner,
        count: 1,
        summary: "sign an owner in to an account, for their agents to use",
        run: &connected/3
      },
      %Command{
        name: "connection disconnect",
        group: "Connections",
        arguments: "PROVIDER",
        switches: @owner,
        count: 1,
        summary: "forget an owner's account",
        run: &disconnected/3
      }
    ]
  end

  defp owner(cx, flags), do: Context.owner(cx, flags, cx.org)

  defp servers([], flags, cx) do
    with {:ok, %{"servers" => servers} = answer} <-
           Context.call(cx, "servers.list", %{"owner" => owner(cx, flags)}) do
      Table.show(cx, answer,
        header: ["SERVER", "URL", "SIGNS IN WITH"],
        rows: for(server <- servers, do: [server["name"], server["url"], server["auth"]]),
        empty: "No servers added."
      )
    end
  end

  defp added([name], %{url: url} = flags, cx) do
    input =
      %{"owner" => owner(cx, flags), "name" => name, "url" => url, "auth" => auth(flags)}
      |> Context.put("only", only(flags[:only]))

    with {:ok, answer} <- Context.call(cx, "servers.add", input),
         do: Context.done(cx, answer, "Added #{name}. Agents reach it as #{name}/*.")
  end

  defp added([_name], _flags, _cx), do: {:error, "Give the server's --url."}

  defp auth(%{secret: secret}), do: %{"secret" => %{"name" => secret}}
  defp auth(%{oauth: true} = flags), do: %{"oauth" => %{"scopes" => List.wrap(flags[:scope])}}
  defp auth(_flags), do: %{"none" => %{}}

  defp only(nil), do: nil
  defp only(tools), do: String.split(tools, ",", trim: true)

  defp removed([name], flags, cx) do
    input = %{"owner" => owner(cx, flags), "name" => name}

    with {:ok, answer} <- Context.call(cx, "servers.remove", input),
         do: Context.done(cx, answer, "Removed #{name}.")
  end

  defp targets([], flags, cx) do
    with {:ok, %{"targets" => targets} = answer} <-
           Context.call(cx, "notify_targets.list", %{"owner" => owner(cx, flags)}) do
      Table.show(cx, answer,
        header: ["TARGET", "KIND", "URL"],
        rows: for(target <- targets, do: [target["name"], target["kind"], target["url"]]),
        empty: "No notify targets."
      )
    end
  end

  defp target_added([name], %{url: url} = flags, cx) do
    input =
      %{"owner" => owner(cx, flags), "name" => name, "url" => url}
      |> Context.put("secret", flags[:secret] && %{"name" => flags[:secret]})

    with {:ok, answer} <- Context.call(cx, "notify_targets.add", input),
         do: Context.done(cx, answer, "Added #{name}. Agents route to it with notify: #{name}.")
  end

  defp target_added([_name], _flags, _cx), do: {:error, "Give the webhook's --url."}

  defp target_removed([name], flags, cx) do
    input = %{"owner" => owner(cx, flags), "name" => name}

    with {:ok, answer} <- Context.call(cx, "notify_targets.remove", input),
         do: Context.done(cx, answer, "Removed #{name}.")
  end

  defp connections([], flags, cx) do
    with {:ok, %{"connections" => connections} = answer} <-
           Context.call(cx, "connections.list", %{"owner" => owner(cx, flags)}) do
      Table.show(cx, answer,
        header: ["ACCOUNT", "CONNECTED"],
        rows:
          for(
            connection <- connections,
            do: [connection["provider"], held(connection["connected"])]
          ),
        empty: "No accounts are offered."
      )
    end
  end

  defp held(true), do: "yes"
  defp held(_connected), do: "no"

  defp connected([provider], flags, cx) do
    input = %{"owner" => owner(cx, flags), "provider" => provider}

    with {:ok, answer} <- Context.call(cx, "connections.connect", input) do
      Context.show(cx, answer, fn answer -> signing_in(cx, provider, answer) end)
    end
  end

  defp signing_in(cx, provider, %{"connected" => true}),
    do: Context.puts(cx, "#{provider} is connected already.")

  defp signing_in(cx, provider, %{"authorization" => %{"url" => url}}),
    do: Context.puts(cx, ["Sign in to #{provider} at ", Owl.Data.tag(url, :cyan)])

  defp disconnected([provider], flags, cx) do
    input = %{"owner" => owner(cx, flags), "provider" => provider}

    with {:ok, answer} <- Context.call(cx, "connections.disconnect", input),
         do: Context.done(cx, answer, "Disconnected #{provider}.")
  end
end
