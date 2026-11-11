defmodule WardrikDaemon.SettingsTools do
  @moduledoc """
  The `settings` tools: an agent reads the daemon's MCP servers, notify targets, OAuth apps and
  secret names, and proposes new ones.

      tools: [settings]

  | Tool | What it does |
  | --- | --- |
  | `settings_list` | Lists an owner's servers, notify targets, OAuth apps or secrets, never a secret's value. |
  | `server_add`, `notify_target_add`, `oauth_app_add` | Adds one. It asks a person unless the policy allows it. |
  | `secret_request` | Answers where a person seals a secret: the dashboard's Secrets page, and the `wardrik vault put` command. |

    * Each acts for the agent's principal, with actor `{:agent, id}`, and is checked as the HTTP
      API checks it. See `WardrikDaemon.Settings`.
    * The owner is the agent's principal unless the call names another.
    * An agent never sees or sets a secret's value. A person seals it.
    * Removing one is a person's job, in the dashboard or with the CLI.
  """

  @behaviour WardrikCore.Capability

  alias Wardrik.Error
  alias WardrikCore.Tool
  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Config
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Secrets
  alias WardrikDaemon.Settings

  @adds [
    {"server_add", "servers", "Add an MCP server that agents can use."},
    {"notify_target_add", "notify_targets",
     "Add a notify target: a webhook that gets a notice when an agent parks, fails or finishes."},
    {"oauth_app_add", "oauth_apps",
     "Add an OAuth app, such as Google or GitHub, that people connect their accounts with."}
  ]

  @owner %{
    "type" => "string",
    "description" =>
      "Whose it is: an org, a person as ORG/@NAME, or deployment. Your own owner unless set."
  }

  @impl WardrikCore.Capability
  def tools(%WardrikCore.Context{agent_id: id, principal: principal}, opts) do
    me = %{daemon: Keyword.fetch!(opts, :daemon), id: id, principal: principal}

    [list(me), request(me)] ++ for {name, kind, about} <- @adds, do: add(me, name, kind, about)
  end

  defp list(me) do
    Tool.new!(
      name: "settings_list",
      description:
        "List an owner's MCP servers, notify targets, OAuth apps or secrets. Secrets are listed by name and purpose, never by value.",
      schema: %{
        "type" => "object",
        "required" => ["kind"],
        "properties" => %{
          "kind" => %{"enum" => Settings.kinds() ++ ["secrets"]},
          "owner" => @owner
        }
      },
      run: fn args, _context ->
        run(me, args, fn scope, owner -> listed(me.daemon, scope, args["kind"], owner) end)
      end,
      annotations: [read_only: true, idempotent: true]
    )
  end

  defp add(me, name, kind, about) do
    input = Settings.input(kind)

    Tool.new!(
      name: name,
      description: about <> " " <> (input["description"] || ""),
      schema: put_in(input, ["properties", "owner"], @owner),
      run: fn args, _context ->
        run(me, args, fn scope, owner ->
          Settings.add(me.daemon, scope, kind, owner, Map.delete(args, "owner"))
        end)
      end,
      annotations: [gated: true]
    )
  end

  defp request(me) do
    Tool.new!(
      name: "secret_request",
      description:
        "Answer where a person seals a secret, such as an API key: a link to the dashboard's Secrets page and the command to run. Give both to the person. You never see or set the value.",
      schema: %{
        "type" => "object",
        "required" => ["name", "purpose"],
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The secret's name, as GITHUB_TOKEN"},
          "purpose" => %{"enum" => Enum.sort(Secrets.purposes())},
          "owner" => @owner
        }
      },
      run: fn args, _context ->
        run(me, args, fn scope, owner -> where(me.daemon, scope, owner, args) end)
      end,
      annotations: [read_only: true, idempotent: true]
    )
  end

  defp run(%{principal: nil, id: id}, _args, _fun),
    do: {:error, "#{id} acts for no one, so it can't reach the settings."}

  defp run(me, args, fun) do
    scope = Wardrik.as(me.daemon.wardrik, me.principal, actor: {:agent, me.id})

    case fun.(scope, args["owner"] || me.principal.id) do
      {:ok, answer} -> {:ok, answer}
      {:error, %Error{message: message}} -> {:error, message}
    end
  end

  defp listed(daemon, scope, "secrets", owner) do
    with :ok <- Allowed.owned(daemon, scope, owner, {"secret.read", :secret}),
         do: {:ok, %{"secrets" => Secrets.list(daemon.wardrik, owner)}}
  end

  defp listed(daemon, scope, kind, owner) do
    with {:ok, items} <- Settings.list(daemon, scope, kind, owner), do: {:ok, %{kind => items}}
  end

  # The agent can't seal a secret, so it hands a person the page and the command.
  defp where(daemon, scope, owner, %{"name" => name, "purpose" => purpose}) do
    with :ok <- Allowed.owned(daemon, scope, owner, {"secret.read", :secret}) do
      {:ok,
       %{}
       |> put("url", page(daemon, owner))
       |> put("command", command(daemon.config, owner, name, purpose))}
    end
  end

  defp page(%{web: nil}, _owner), do: nil

  defp page(%{config: config}, owner),
    do:
      String.trim_trailing(Config.base_url(config), "/") <>
        "/web/secrets?" <> URI.encode_query(%{"owner" => owner})

  defp command(config, owner, name, purpose) do
    case flag(config, owner) do
      nil -> nil
      flag -> String.trim("wardrik vault put #{name} --for #{purpose} #{flag}")
    end
  end

  defp flag(_config, "deployment"), do: ""

  # --user names a person of the deployment's own org; others have no flag, only the page.
  defp flag(%Config{org: org}, owner) do
    case {Owners.org(owner), Owners.person(owner)} do
      {^org, person} when is_binary(person) -> "--user " <> person
      {org, nil} -> "--org " <> org
      _other_org -> nil
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
