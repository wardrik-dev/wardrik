defmodule WardrikDaemon.Config do
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Cluster
  alias WardrikDaemon.Config.Access
  alias WardrikDaemon.Config.Channels
  alias WardrikDaemon.Config.MCP
  alias WardrikDaemon.Config.Notify
  alias WardrikDaemon.Config.OAuth
  alias WardrikDaemon.Config.Options
  alias WardrikDaemon.Config.Orgs
  alias WardrikDaemon.Dirs

  @wardrik [:deployment, :idle_timeout, :retention, :triggers]

  @schema [
            org: [type: :string, default: "default", doc: "The deployment's org."],
            orgs: [
              type: {:map, :string, :any},
              default: %{},
              doc: "Other orgs to run agents for. See `WardrikDaemon.Config.Orgs`."
            ],
            roles: [
              type: {:map, :string, :any},
              default: %{},
              doc: "What each role may do. See `WardrikDaemon.Config.Access`."
            ],
            bindings: [
              type: {:list, :any},
              default: [],
              doc: "Who holds each role, in which org. See `WardrikDaemon.Config.Access`."
            ],
            deployment_keys: [
              type: :boolean,
              default: true,
              doc:
                "`true` to let agents use the API keys sealed as the deployment's where their " <>
                  "owners hold none. See `WardrikDaemon.Keys`."
            ],
            allow_private_urls: [
              type: :boolean,
              default: false,
              doc:
                "`true` to let orgs and people add MCP servers, webhooks and OAuth apps at " <>
                  "loopback, private and link-local addresses. For local use only. See " <>
                  "`WardrikDaemon.Egress`."
            ],
            base_url: [
              type: :string,
              doc:
                "Where people and services reach the deployment. The HTTP API's URL unless set."
            ],
            defaults: [
              type: {:map, :string, :any},
              default: %{},
              doc: "What every agent's file gets where it says nothing."
            ],
            models: [
              type: :keyword_list,
              default: [],
              doc: "How agents call models.",
              keys: [
                prices: [
                  type: {:map, :string, :any},
                  default: %{},
                  doc: """
                  Prices for models the catalog lacks, by model spec, in dollars per million
                  tokens: `input`, `output`, `cache_read` and `cache_write`, or `priced_as` another
                  model, each with an optional `markup`. See `Wardrik.Setup.price/2`.
                  """
                ],
                options: [
                  type: {:map, :string, :any},
                  default: %{},
                  doc: """
                  Options for every model call, as `ReqLLM` takes them, such as `temperature` or
                  `base_url`. An agent's `model_options` merge over them. See `Wardrik`'s
                  `:model_options`.
                  """
                ],
                gateway: [
                  type: {:map, :string, :any},
                  default: %{},
                  doc: """
                  What every model call goes through: `fallbacks` by model, `limits` by provider
                  (`requests_per_minute`, `tokens_per_minute`), `breaker` (`failures`, and
                  `within` and `open_for` in seconds), and `wait`, the longest a call waits, in
                  seconds. See `WardrikGateway`.
                  """
                ]
              ]
            ],
            mcp: [
              type: {:map, :string, :any},
              default: %{},
              doc: "MCP servers agents may call. See `WardrikDaemon.Config.MCP`."
            ],
            oauth: [
              type: {:map, :string, :any},
              doc: "Services people sign in to. See `WardrikDaemon.Config.OAuth`."
            ],
            channels: [
              type: {:map, :string, :any},
              default: %{},
              doc: "Chat apps agents are reached through. See `WardrikDaemon.Config.Channels`."
            ],
            notify: [
              type: {:map, :string, :any},
              default: %{},
              doc: "Where agents' notices go. See `WardrikDaemon.Config.Notify`."
            ],
            workspace: [
              type: {:map, :string, :any},
              doc: """
              `shared`: agents' workspaces other agents may mount, by the sharing agent, as
              `agent:NAME`. Each has `read` and `write` lists of the agents that mount it, as
              `agent:NAME`. Each name is an agent's in the mounting agent's own org.
              """
            ],
            brave: [
              type: :keyword_list,
              doc: "Brave Search, for `web_search`.",
              keys: [
                api_key: [type: :string, required: true, doc: "The key it searches with."]
              ]
            ],
            vault: [
              type: :keyword_list,
              default: [],
              doc: "The vault.",
              keys: [keys: [type: {:list, :string}, default: [], doc: "The vault's keys."]]
            ],
            http: [
              type: :keyword_list,
              default: [],
              doc: "The HTTP API.",
              keys: [
                port: [
                  type: {:custom, __MODULE__, :port, []},
                  default: 4747,
                  doc: "The port it listens on."
                ],
                ip: [
                  type: {:custom, __MODULE__, :ip, []},
                  default: "127.0.0.1",
                  doc: "The address it listens on. `WARDRIK_HTTP_IP` unless set."
                ],
                trusted_workers: [
                  type: :boolean,
                  default: false,
                  doc: "`true` to treat tool workers' answers as the deployment's own."
                ]
              ]
            ],
            cluster: [
              type: :keyword_list,
              doc: "Other daemons this one runs as one with. See `WardrikDaemon.Cluster`.",
              keys: [
                nodes: [
                  type: {:list, :string},
                  doc: "Every node, this one among them: `a` on this machine, or `wardrik@HOST`."
                ],
                dns: [
                  type: :string,
                  doc: "A name that resolves to an address for each node, in place of `nodes`."
                ],
                size: [type: :pos_integer, doc: "How many nodes there are, with `dns`."]
              ]
            ],
            storage: [
              type: :keyword_list,
              doc: "Where everything is kept. The node's disk unless set.",
              keys: [
                postgres: [
                  type: :keyword_list,
                  required: true,
                  doc: "Keeps everything in Postgres.",
                  keys: [
                    url: [
                      type: {:custom, __MODULE__, :postgres, []},
                      required: true,
                      doc: "A `postgres://` URL."
                    ]
                  ]
                ]
              ]
            ]
          ] ++ Keyword.take(Wardrik.schema().schema, @wardrik)

  @moduledoc """
  Reads `config.yaml`.

      org: acme
      base_url: https://agents.acme.example
      defaults:
        model: anthropic:claude-haiku-4-5
      http:
        port: 4747

  ## Keys

  #{NimbleOptions.docs(@schema)}

  #{Enum.map_join(@wardrik, ", ", &"`#{&1}`")} are `Wardrik.start_link/1`'s options.

    * `tools`, `tokens` and `ssh` are skipped with a warning. Any other unknown key is
      an error that names its path.
    * YAML writes atoms as strings (`flow: device`) and keyword lists as maps.
    * `${NAME}` reads the environment, the env file, then the deployment's vault secret `NAME`.
      `vault`, `http`, `storage` and `cluster` read the environment only.
  """

  @bootstrap ~w(vault http storage cluster)
  @later ~w(tools tokens ssh)

  defstruct org: "default",
            orgs: %{},
            access: nil,
            base_url: nil,
            deployment_keys: true,
            allow_private_urls: false,
            defaults: %{},
            prices: %{},
            model_options: [],
            gateway: [],
            mcp: [],
            oauth: nil,
            channels: [],
            notify: [],
            workspace: [],
            brave: nil,
            keys: [],
            port: 4747,
            ip: {127, 0, 0, 1},
            trusted_workers: false,
            storage: nil,
            cluster: nil,
            wardrik: [],
            warnings: []

  @type t() :: %__MODULE__{
          org: String.t(),
          orgs: %{String.t() => Orgs.entry()},
          access: Access.t(),
          base_url: String.t() | nil,
          deployment_keys: boolean(),
          allow_private_urls: boolean(),
          defaults: map(),
          prices: %{String.t() => keyword()},
          model_options: keyword(),
          gateway: keyword(),
          mcp: keyword(),
          oauth: keyword() | nil,
          channels: keyword(),
          notify: keyword(),
          workspace: [shared: %{String.t() => %{read: [String.t()], write: [String.t()]}}],
          brave: String.t() | nil,
          keys: [String.t()],
          port: :inet.port_number(),
          ip: :inet.ip_address(),
          trusted_workers: boolean(),
          storage: {:postgres, String.t()} | nil,
          cluster: Cluster.t() | nil,
          wardrik: keyword(),
          warnings: [String.t()]
        }

  @typedoc "Looks up the deployment's secret `name` in the vault. Returns `:error` if it isn't there."
  @type vault() :: (String.t() -> {:ok, String.t()} | :error)

  @doc """
  Reads `config.yaml` from the config directory, filling `${NAME}` from `env`, then `vault`.

  A missing file reads as the defaults.
  """
  @spec read(Dirs.t(), %{String.t() => String.t()}, vault() | nil) ::
          {:ok, t()} | {:error, String.t()}
  def read(dirs, env, vault \\ nil) do
    path = Dirs.config(dirs, "config.yaml")

    with {:ok, yaml} <- yaml(path, env),
         {:ok, early} <- interpolated(Map.take(yaml, @bootstrap), env, nil),
         {:ok, late} <- interpolated(Map.drop(yaml, @bootstrap ++ @later), env, vault),
         {:ok, opts} <- Options.validate(Map.merge(early, late), @schema, nil),
         {:ok, config} <- sections(opts) do
      {:ok, %{config | warnings: later(yaml)}}
    else
      {:error, why} -> {:error, "#{path}: #{why}"}
    end
  end

  @doc "Reads what's needed before the vault opens: the vault's keys, where HTTP listens, `storage` and `cluster`. Fills in `${NAME}` from `env` alone."
  @spec bootstrap(Dirs.t(), %{String.t() => String.t()}) ::
          {:ok,
           %{
             keys: [String.t()],
             port: :inet.port_number(),
             ip: :inet.ip_address(),
             storage: {:postgres, String.t()} | nil,
             cluster: Cluster.t() | nil
           }}
          | {:error, String.t()}
  def bootstrap(dirs, env) do
    path = Dirs.config(dirs, "config.yaml")

    with {:ok, yaml} <- yaml(path, env),
         {:ok, early} <- interpolated(Map.take(yaml, @bootstrap), env, nil),
         {:ok, opts} <- Options.validate(Map.merge(Map.drop(yaml, @later), early), @schema, nil),
         {:ok, cluster} <- Cluster.new(opts[:cluster]) do
      {:ok,
       %{
         keys: opts[:vault][:keys],
         port: opts[:http][:port],
         ip: opts[:http][:ip],
         storage: storage(opts[:storage]),
         cluster: cluster
       }}
    else
      {:error, why} -> {:error, "#{path}: #{why}"}
    end
  end

  @doc "Returns the `${NAME}`s `config.yaml` names outside `vault`, `http`, `storage` and `cluster`. The vault may hold these."
  @spec sealable(Dirs.t()) :: [String.t()]
  def sealable(dirs) do
    case yaml(Dirs.config(dirs, "config.yaml")) do
      {:ok, yaml} -> yaml |> Map.drop(@bootstrap ++ @later) |> names() |> Enum.uniq()
      {:error, _why} -> []
    end
  end

  @doc "Returns the HTTP API's URL. An API bound to `0.0.0.0` is reached at `127.0.0.1`."
  @spec url(t()) :: String.t()
  def url(%__MODULE__{ip: {0, 0, 0, 0}, port: port}), do: "http://127.0.0.1:#{port}"
  def url(%__MODULE__{ip: ip, port: port}), do: "http://#{:inet.ntoa(ip)}:#{port}"

  @doc "Returns where people and services reach the deployment: `base_url`, or `url/1` if it isn't set."
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{base_url: nil} = config), do: url(config)
  def base_url(%__MODULE__{base_url: base_url}), do: String.trim_trailing(base_url, "/")

  @doc false
  def port(port) when is_integer(port) and port in 0..65_535, do: {:ok, port}
  def port(_port), do: {:error, "is a port number"}

  @doc false
  def ip(text) when is_binary(text) do
    case :inet.parse_address(to_charlist(text)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> ip(nil)
    end
  end

  def ip(_ip), do: {:error, "is an address, as 127.0.0.1"}

  @doc false
  def postgres("postgres" <> _rest = url), do: {:ok, url}
  def postgres(_url), do: {:error, "is a postgres:// URL"}

  defp yaml(path, %{"WARDRIK_HTTP_IP" => ip}) do
    with {:ok, yaml} <- yaml(path) do
      case Map.get(yaml, "http", %{}) do
        http when is_map(http) -> {:ok, Map.put(yaml, "http", Map.put_new(http, "ip", ip))}
        _other -> {:ok, yaml}
      end
    end
  end

  defp yaml(path, _env), do: yaml(path)

  defp yaml(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} when is_map(yaml) -> {:ok, yaml}
      {:ok, nil} -> {:ok, %{}}
      {:ok, _other} -> {:error, "is a set of keys"}
      {:error, %YamlElixir.FileNotFoundError{}} -> {:ok, %{}}
      {:error, error} -> {:error, "isn't YAML: #{Exception.message(error)}"}
    end
  end

  defp later(yaml),
    do:
      for(
        key <- @later,
        Map.has_key?(yaml, key),
        do: "#{key} isn't supported here yet, so it's passed over"
      )

  defp sections(opts) do
    org = opts[:org]

    with {:ok, mcp} <- MCP.read(opts[:mcp]),
         {:ok, channels} <- Channels.read(opts[:channels], org),
         {:ok, notify} <- Notify.read(opts[:notify], Enum.map(channels, &elem(&1, 0))),
         {:ok, orgs} <- Orgs.read(opts[:orgs], defined(mcp, channels, notify)),
         {:ok, access} <- Access.read(opts[:roles], opts[:bindings], declared(orgs, org)),
         {:ok, channels} <- owned(channels, orgs, org),
         {:ok, workspace} <- workspace(opts[:workspace]),
         {:ok, prices} <- prices(opts[:models][:prices]),
         {:ok, model_options} <- model_options(opts[:models][:options]),
         {:ok, gateway} <- gateway(opts[:models][:gateway]),
         {:ok, cluster} <- Cluster.new(opts[:cluster]) do
      config = %__MODULE__{
        org: org,
        orgs: orgs,
        access: access,
        base_url: opts[:base_url],
        deployment_keys: opts[:deployment_keys],
        allow_private_urls: opts[:allow_private_urls],
        defaults: opts[:defaults],
        prices: prices,
        model_options: model_options,
        gateway: gateway,
        mcp: mcp,
        channels: channels,
        notify: notify,
        workspace: workspace,
        brave: opts[:brave][:api_key],
        keys: opts[:vault][:keys],
        port: opts[:http][:port],
        ip: opts[:http][:ip],
        trusted_workers: opts[:http][:trusted_workers],
        storage: storage(opts[:storage]),
        cluster: cluster,
        wardrik: Keyword.take(opts, @wardrik)
      }

      with {:ok, oauth} <- OAuth.read(opts[:oauth], base_url(config) <> "/oauth"),
           do: {:ok, %{config | oauth: oauth}}
    end
  end

  defp declared(orgs, org), do: [org | Map.keys(orgs) -- ["*"]]

  defp storage(nil), do: nil
  defp storage(postgres: [url: url]), do: {:postgres, url}

  defp defined(mcp, channels, notify) do
    %{
      "mcp" => Enum.map(mcp, &to_string(elem(&1, 0))),
      "channels" => Enum.map(channels, &to_string(elem(&1, 0))),
      "notify" => Enum.map(notify[:targets], &to_string(elem(&1, 0)))
    }
  end

  defp owned(channels, orgs, org) do
    Options.each(channels, fn name, {adapter, opts} ->
      with {:ok, owner} <- owner(orgs, name, org),
           do: {:ok, {adapter, Keyword.replace!(opts, :owner, owner)}}
    end)
  end

  defp owner(orgs, name, org) do
    case Orgs.using(orgs, kind: :channels, name: to_string(name), org: org) do
      :all ->
        {:ok, "*"}

      [owner] ->
        {:ok, owner}

      several ->
        {:error,
         "channels.#{name}: is listed by #{Enum.join(several, " and ")}; a channel serves one org, or every org under \"*\""}
    end
  end

  defp prices(models) do
    Options.loaded([Wardrik.Setup])
    with {:ok, prices} <- Options.each(models, &price/2), do: {:ok, Map.new(prices)}
  end

  defp price(spec, price) when is_map(price) do
    path = "models.prices.#{spec}"

    with {:ok, price} <- Options.convert(price, [], path),
         {:ok, _priced} <- Options.built(fn -> Wardrik.Setup.price(spec, price) end, path),
         do: {:ok, price}
  end

  defp price(spec, _price),
    do:
      {:error,
       "models.prices.#{spec}: holds input and output, dollars per million tokens, or priced_as, and markup"}

  # Checked against ReqLLM's own options, without their defaults: each call fills those in.
  defp model_options(yaml) do
    schema = ReqLLM.Provider.Options.generation_schema().schema

    with {:ok, options} <- Options.convert(yaml, schema, "models.options"),
         {:ok, _checked} <- Options.checked(options, schema, "models.options"),
         do: {:ok, options}
  end

  @gateway "models.gateway"
  @breaker [failures: [], within: [], open_for: []]
  @limit [requests_per_minute: [], tokens_per_minute: []]

  # YAML gives seconds and maps; the gateway takes milliseconds and keyword lists.
  defp gateway(yaml) do
    schema = WardrikGateway.schema().schema

    with {:ok, opts} <- Options.convert(Map.drop(yaml, ["limits", "breaker"]), schema, @gateway),
         {:ok, limits} <- Options.each(Map.get(yaml, "limits", %{}), &limit/2),
         {:ok, breaker} <-
           Options.convert(Map.get(yaml, "breaker", %{}), @breaker, "#{@gateway}.breaker") do
      opts =
        opts
        |> Keyword.update(:wait, nil, &milliseconds/1)
        |> Keyword.put(:limits, Map.new(limits))
        |> Keyword.put(:breaker, Enum.map(breaker, &breaker_setting/1))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      with {:ok, _checked} <- Options.checked(opts, schema, @gateway), do: {:ok, opts}
    end
  end

  defp limit(provider, limit),
    do: Options.convert(limit, @limit, "#{@gateway}.limits.#{provider}")

  defp breaker_setting({:failures, failures}), do: {:failures, failures}
  defp breaker_setting({key, seconds}), do: {key, milliseconds(seconds)}

  defp milliseconds(seconds) when is_number(seconds), do: round(seconds * 1000)
  defp milliseconds(other), do: other

  defp workspace(nil), do: {:ok, []}

  defp workspace(%{"shared" => shared} = workspace)
       when is_map(shared) and map_size(workspace) == 1 do
    case Enum.find(shared, fn {agent, rule} -> not (agent?(agent) and rule?(rule)) end) do
      nil ->
        {:ok,
         [
           shared:
             Map.new(shared, fn {agent, rule} ->
               {name(agent), %{read: mounting(rule, "read"), write: mounting(rule, "write")}}
             end)
         ]}

      {agent, _rule} ->
        {:error,
         "workspace.shared.#{agent}: is an agent, as agent:NAME, holding read and write, each a list of agents, as agent:NAME"}
    end
  end

  defp workspace(_workspace),
    do: {:error, "workspace: holds shared, the agents' workspaces other agents may mount"}

  defp rule?(rule) when is_map(rule),
    do:
      Enum.all?(rule, fn {key, agents} ->
        key in ["read", "write"] and is_list(agents) and Enum.all?(agents, &agent?/1)
      end)

  defp rule?(_rule), do: false

  # An agent as agent:NAME exactly: no patterns.
  defp agent?(agent), do: match?({:ok, _name}, AgentRecords.subject(agent))

  defp name(agent) do
    {:ok, name} = AgentRecords.subject(agent)
    name
  end

  defp mounting(rule, mode), do: rule |> Map.get(mode, []) |> Enum.map(&name/1)

  defp interpolated(term, env, vault) do
    values = term |> names() |> Enum.uniq() |> Map.new(&{&1, value(&1, env, vault)})

    case for {name, :error} <- values, do: name do
      [] -> {:ok, replaced(term, values)}
      [name | _rest] -> {:error, "names ${#{name}}, which #{unset(vault)}"}
    end
  end

  defp value(name, env, vault) do
    case {Map.fetch(env, name), vault} do
      {{:ok, value}, _vault} -> {:ok, value}
      {:error, nil} -> :error
      {:error, vault} -> vault.(name)
    end
  end

  defp unset(nil), do: "neither the environment nor the env file sets"
  defp unset(_vault), do: "neither the environment, the env file nor the vault holds"

  defp names(text) when is_binary(text),
    do: for([_whole, name] <- Regex.scan(~r/\$\{(\w+)\}/, text), do: name)

  defp names(map) when is_map(map), do: Enum.flat_map(map, fn {_key, value} -> names(value) end)
  defp names(list) when is_list(list), do: Enum.flat_map(list, &names/1)
  defp names(_other), do: []

  defp replaced(text, values) when is_binary(text) do
    Regex.replace(~r/\$\{(\w+)\}/, text, fn _whole, name ->
      {:ok, value} = Map.fetch!(values, name)
      value
    end)
  end

  defp replaced(map, values) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, replaced(value, values)} end)

  defp replaced(list, values) when is_list(list), do: Enum.map(list, &replaced(&1, values))
  defp replaced(other, _values), do: other
end
