defmodule WardrikDaemon.CLI.Servers do
  @moduledoc false

  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Table
  alias WardrikDaemon.CLI.Terminal

  @owner [org: :string, user: :string]
  @poll :timer.seconds(1)

  @doc "Returns the commands on MCP servers, notify targets, OAuth apps and connections."
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
        name: "provider ls",
        group: "OAuth apps",
        switches: @owner,
        summary: "the OAuth apps an owner's people sign in with",
        run: &providers/3
      },
      %Command{
        name: "provider add",
        group: "OAuth apps",
        arguments: "NAME",
        switches:
          [
            issuer: :string,
            resource: :string,
            authorization_endpoint: :string,
            token_endpoint: :string,
            client_id: :string,
            secret: :string,
            scope: :keep,
            flow: :string
          ] ++ @owner,
        count: 1,
        summary: "add an OAuth app an owner's people sign in to NAME with",
        details: [
          "Give its --issuer, its --resource, or both --authorization-endpoint and",
          "--token-endpoint, and its --client-id. --secret names the owner's secret in the vault,",
          "sealed for client_secret. --flow device signs people in with a code."
        ],
        run: &provider_added/3
      },
      %Command{
        name: "provider rm",
        group: "OAuth apps",
        arguments: "NAME",
        switches: @owner,
        count: 1,
        summary: "remove an OAuth app an owner added",
        run: &provider_removed/3
      },
      %Command{
        name: "connection ls",
        group: "Connections",
        summary: "the accounts you can connect, and which you hold",
        run: &connections/3
      },
      %Command{
        name: "connection connect",
        group: "Connections",
        arguments: "PROVIDER",
        count: 1,
        summary: "sign in to an account, for your agents to use",
        details: [
          "A device sign-in shows a code to enter at the provider. It waits until the sign-in is",
          "granted, declined or expired. A browser sign-in asks for the code its page shows."
        ],
        run: &connected/3
      },
      %Command{
        name: "connection pair",
        group: "Connections",
        arguments: "PROVIDER CODE",
        count: 2,
        summary: "finish signing in with the code the sign-in page showed",
        run: &paired/3
      },
      %Command{
        name: "connection disconnect",
        group: "Connections",
        arguments: "PROVIDER",
        count: 1,
        summary: "forget your account",
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

  defp providers([], flags, cx) do
    with {:ok, %{"providers" => providers} = answer} <-
           Context.call(cx, "providers.list", %{"owner" => owner(cx, flags)}) do
      Table.show(cx, answer,
        header: ["PROVIDER", "OWNER", "SIGNS IN AT"],
        rows:
          for(
            provider <- providers,
            do: [provider["name"], provider["owner"], signs_in_at(provider)]
          ),
        empty: "No OAuth apps."
      )
    end
  end

  defp signs_in_at(provider),
    do: provider["issuer"] || provider["resource"] || provider["authorization_endpoint"]

  defp provider_added([name], flags, cx) do
    fields =
      for key <- [:issuer, :resource, :authorization_endpoint, :token_endpoint, :client_id, :flow],
          value = flags[key],
          value != nil,
          into: %{},
          do: {Atom.to_string(key), value}

    input =
      %{"owner" => owner(cx, flags), "name" => name}
      |> Map.merge(fields)
      |> Context.put("scopes", flags[:scope] && List.wrap(flags[:scope]))
      |> Context.put("client_secret", flags[:secret] && %{"name" => flags[:secret]})

    with {:ok, answer} <- Context.call(cx, "providers.add", input),
         do: Context.done(cx, answer, "Added #{name}. People sign in to #{name} with it.")
  end

  defp provider_removed([name], flags, cx) do
    input = %{"owner" => owner(cx, flags), "name" => name}

    with {:ok, answer} <- Context.call(cx, "providers.remove", input),
         do: Context.done(cx, answer, "Removed #{name}.")
  end

  defp connections([], _flags, cx) do
    with {:ok, %{"connections" => connections} = answer} <-
           Context.call(cx, "connections.list", %{}) do
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

  defp connected([provider], _flags, cx) do
    with {:ok, answer} <- Context.call(cx, "connections.connect", %{"provider" => provider}) do
      if cx.json?, do: Context.show(cx, answer, & &1), else: signing_in(cx, provider, answer)
    end
  end

  defp signing_in(cx, provider, %{"connected" => true}),
    do: Context.puts(cx, "#{provider} is connected already.")

  # The provider's own code: it's entered there, and the grant comes to the daemon.
  defp signing_in(cx, provider, %{"authorization" => %{"url" => url, "code" => code}}) do
    Context.puts(cx, [
      "Sign in to #{provider} at ",
      Owl.Data.tag(url, :cyan),
      " with the code ",
      Owl.Data.tag(code, :cyan)
    ])

    granted(cx, provider)
  end

  defp signing_in(cx, provider, %{"authorization" => %{"url" => url}}) do
    Context.puts(cx, ["Sign in to #{provider} at ", Owl.Data.tag(url, :cyan)])

    if cx.terminal.input?,
      do: pairing(cx, provider),
      else:
        Context.puts(
          cx,
          "Then finish with the code the page shows: #{cx.program} connection pair #{provider} CODE"
        )
  end

  # Waits while the sign-in is under way. It ends once granted, refused or expired.
  defp granted(cx, provider) do
    with {:ok, %{"connections" => connections}} <- Context.call(cx, "connections.list", %{}) do
      case Enum.find(connections, &(&1["provider"] == provider)) do
        %{"connected" => true} ->
          Context.puts(cx, "Connected #{provider}.")

        %{"signing_in" => true} ->
          Process.sleep(@poll)
          granted(cx, provider)

        _ended ->
          {:error, "The sign-in to #{provider} ended without connecting it. Connect again."}
      end
    end
  end

  # The daemon counts wrong codes, and ends the sign-in after its last.
  defp pairing(cx, provider) do
    case Terminal.ask(cx.terminal, "Code from the page: ") do
      nil ->
        {:error, "No code given. Finish with: #{cx.program} connection pair #{provider} CODE"}

      code ->
        cx |> paired_with(provider, code) |> retried(cx, provider)
    end
  end

  defp paired_with(cx, provider, code), do: paired([provider, code], %{}, cx)

  defp retried({:error, why}, cx, provider) do
    if why =~ "has ended" do
      {:error, why}
    else
      Context.puts(cx, why)
      pairing(cx, provider)
    end
  end

  defp retried(done, _cx, _provider), do: done

  defp paired([provider, code], _flags, cx) do
    input = %{"provider" => provider, "code" => code}

    with {:ok, answer} <- Context.call(cx, "connections.pair", input),
         do: Context.done(cx, answer, "Connected #{provider}.")
  end

  defp disconnected([provider], _flags, cx) do
    with {:ok, answer} <- Context.call(cx, "connections.disconnect", %{"provider" => provider}),
         do: Context.done(cx, answer, "Disconnected #{provider}.")
  end
end
