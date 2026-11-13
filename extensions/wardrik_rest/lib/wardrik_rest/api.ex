defmodule WardrikRest.API do
  alias WardrikRest.Operation
  alias WardrikRest.Parameter
  alias WardrikRest.Reader
  alias WardrikRest.Schema
  alias WardrikRest.Spec

  @name_limit 64

  @schema NimbleOptions.new!(
            name: [
              type: :string,
              required: true,
              doc: "The prefix of the tools' names, as `\"ga4\"` for `ga4__properties_runReport`."
            ],
            base_url: [
              type: :string,
              required: true,
              doc:
                "Where the API is reached, as `\"https://analyticsdata.googleapis.com/\"`. Never read from the description."
            ],
            auth: [
              type: {:map, :string, :any},
              default: %{},
              doc:
                "The source of each scheme the description names, as `%{\"oauth2\" => {:credential, \"google\"}}`."
            ],
            schemes: [
              type: {:map, :string, :any},
              default: %{},
              doc:
                "Schemes the description doesn't name, each sent on every operation before its own, as `%{\"token\" => :bearer}`, `{:header, name}` or `{:query, name}`. `:auth` gives each a source."
            ],
            headers: [
              type: {:map, :string, :any},
              default: %{},
              doc:
                "Headers every call sends that the description doesn't name, each a source, as `%{\"developer-token\" => {:key, \"ADS_TOKEN\"}}`."
            ],
            argument_headers: [
              type: {:map, :string, :string},
              default: %{},
              doc:
                "Headers each tool takes as optional arguments, by name with what they're for, as `%{\"login-customer-id\" => \"The manager account's ID\"}`."
            ],
            only: [
              type: {:list, :string},
              default: ["*"],
              doc:
                "The operations to offer, by name or glob, as `[\"properties_run*\"]`. Every operation it can sign in to unless set."
            ],
            read_only: [
              type: {:list, :string},
              default: [],
              doc:
                "Operations that change nothing beyond `GET`s, by name or glob. Many APIs read with `POST`."
            ],
            idempotent: [
              type: {:list, :string},
              default: [],
              doc: "Operations safe to repeat beyond `GET`, `PUT` and `DELETE`, by name or glob."
            ],
            trusted: [
              type: :boolean,
              default: false,
              doc: "`true` stops labelling answers `\"outside\"`."
            ],
            timeout: [
              type: :pos_integer,
              default: 30_000,
              doc: "How long a call may take, in milliseconds."
            ],
            max_result_bytes: [
              type: :pos_integer,
              default: 128 * 1024,
              doc:
                "Bytes of an answer the model gets, as JSON. A longer one is cut, with a note to ask for less."
            ],
            max_schema_bytes: [
              type: :pos_integer,
              default: 16 * 1024,
              doc:
                "Bytes of each tool's schema, as JSON, where it can be. Types deeper than fit are named instead, and the `<name>__describe` tool gives their fields."
            ],
            egress: [
              type: {:fun, 1},
              default: &__MODULE__.https/1,
              doc:
                "Checks `:base_url`, returning `:ok` or `{:error, reason}`. Only `https` unless set; Wardrik's is `Wardrik.Egress.public/1`."
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: "Merged into every request."
            ]
          )

  # The moduledoc lists the options from the schema above.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  @moduledoc """
  An API loaded for agents: the operations offered from its description, where it's reached, and
  where each credential comes from.

      {:ok, analytics} =
        WardrikRest.API.load(discovery,
          name: "ga4",
          base_url: "https://analyticsdata.googleapis.com/",
          auth: %{"oauth2" => {:credential, "google"}},
          only: ["properties_runReport", "properties_getMetadata"],
          read_only: ["properties_run*"]
        )

  Load it once, as your app starts or adds the API, and give it to agents as
  `{WardrikRest, apis: [analytics]}`.

  ## Where secrets come from

  A source is one of:

    * `{:credential, name}` - the token of whoever the turn acts for, from the agent's
      `WardrikCore.Credentials`. Until they sign in, the call waits for them.
    * `{:key, name}` - a key from the agent's `WardrikCore.Keys`, such as the org's own.
    * A string, for a header only, sent as it is.

  Secrets go only to `:base_url`, never into arguments, answers or errors.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @enforce_keys [
    :name,
    :base_url,
    :operations,
    :schemes,
    :auth,
    :headers,
    :read_only,
    :idempotent,
    :schemas
  ]
  defstruct [
    :name,
    :base_url,
    :operations,
    :schemes,
    :auth,
    :headers,
    :read_only,
    :idempotent,
    :schemas,
    types: %{},
    described: [],
    trusted: false,
    timeout: 30_000,
    max_result_bytes: 128 * 1024,
    req_options: []
  ]

  @type source() :: {:credential, String.t()} | {:key, String.t()}

  @type t() :: %__MODULE__{
          name: String.t(),
          base_url: String.t(),
          operations: [Operation.t()],
          schemes: %{String.t() => Spec.place()},
          auth: %{String.t() => source()},
          headers: %{String.t() => source() | String.t()},
          read_only: [String.t()],
          idempotent: [String.t()],
          schemas: %{String.t() => map()},
          types: Schema.types(),
          described: [String.t()],
          trusted: boolean(),
          timeout: pos_integer(),
          max_result_bytes: pos_integer(),
          req_options: keyword()
        }

  @doc "Returns the options `load/2` takes, to check them before loading."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc """
  Reads `source`, a `WardrikRest.Reader` and its options, and keeps the operations `opts` offer.

  Returns `{:error, reason}` if the description can't be read, `:base_url` fails `:egress`,
  `:auth` names a scheme neither the description nor `:schemes` has, or `:only` names an
  operation it doesn't have, can't sign in to, or whose tool name would be over 64 characters. An
  operation only a glob offers is left out where its tool name would be over 64 characters.
  """
  @spec load(Reader.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(source, opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    with {:ok, spec} <- Reader.read(source),
         {:ok, spec} <- added(spec, opts[:schemes]),
         :ok <- opts[:egress].(opts[:base_url]),
         :ok <- schemes(spec, opts[:auth]),
         {:ok, operations} <- offered(spec, opts) do
      operations = Enum.map(operations, &headed(&1, opts[:argument_headers]))
      fitted = Map.new(operations, &{&1.name, fitted(&1, spec, opts)})

      described =
        fitted
        |> Map.values()
        |> Enum.flat_map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.sort()

      {:ok,
       %__MODULE__{
         name: opts[:name],
         base_url: String.trim_trailing(opts[:base_url], "/") <> "/",
         operations: operations,
         schemes: spec.schemes,
         schemas: Map.new(fitted, fn {name, {schema, _cut}} -> {name, schema} end),
         types: spec.types,
         described: described,
         auth: opts[:auth],
         headers: opts[:headers],
         read_only: opts[:read_only],
         idempotent: opts[:idempotent],
         trusted: opts[:trusted],
         timeout: opts[:timeout],
         max_result_bytes: opts[:max_result_bytes],
         req_options: opts[:req_options]
       }}
    end
  end

  defp headed(operation, headers) do
    taken = MapSet.new(operation.parameters, & &1.name)

    added =
      for {name, about} <- Enum.sort(headers), not MapSet.member?(taken, name) do
        %Parameter{name: name, in: :header, schema: %{"type" => "string", "description" => about}}
      end

    %{operation | parameters: operation.parameters ++ added}
  end

  defp fitted(operation, spec, opts) do
    {properties, cut} =
      Schema.fit(
        operation.parameters,
        spec.types,
        opts[:max_schema_bytes],
        {tool_name(opts[:name], operation), describe(opts[:name])}
      )

    required = for %{required: true, name: name} <- operation.parameters, do: name
    schema = %{"type" => "object", "properties" => properties}
    {if(required == [], do: schema, else: Map.put(schema, "required", Enum.sort(required))), cut}
  end

  @doc "Returns the name of the tool that describes `api`'s types, as `ads__describe`."
  @spec describe(t() | String.t()) :: String.t()
  def describe(%__MODULE__{name: name}), do: describe(name)
  def describe(name), do: "#{name}__describe"

  @doc "Returns `:ok` for an `https` URL with a host. The default `:egress`."
  @spec https(String.t()) :: :ok | {:error, String.t()}
  def https(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      _other -> {:error, "#{url} isn't an https URL."}
    end
  end

  @doc """
  Returns the schemes of the first of `operation`'s alternatives the API has sources for, or
  `:error`.
  """
  @spec security(t(), Operation.t()) :: {:ok, [String.t()]} | :error
  def security(%__MODULE__{auth: auth}, operation), do: signed(auth, operation)

  defp signed(auth, %Operation{security: alternatives}) do
    case Enum.find(alternatives, fn schemes -> Enum.all?(schemes, &Map.has_key?(auth, &1)) end) do
      nil -> :error
      schemes -> {:ok, schemes}
    end
  end

  @doc "Returns the annotations of `operation`'s tool: whether it's read-only and idempotent."
  @spec annotations(t(), Operation.t()) :: keyword()
  def annotations(%__MODULE__{} = api, %Operation{name: name, method: method}) do
    read_only = method == :get or listed?(api.read_only, name)
    idempotent = read_only or method in [:put, :delete] or listed?(api.idempotent, name)
    [read_only: read_only, idempotent: idempotent]
  end

  defp added(spec, schemes) when map_size(schemes) == 0, do: {:ok, spec}

  defp added(spec, schemes) do
    case Enum.reject(schemes, fn {_name, place} -> place?(place) end) do
      [] ->
        names =
          schemes
          |> Map.keys()
          |> Enum.sort()

        operations = Enum.map(spec.operations, &%{&1 | security: [names | &1.security]})
        {:ok, %{spec | schemes: Map.merge(spec.schemes, schemes), operations: operations}}

      [{name, _place} | _more] ->
        {:error, "schemes.#{name} is :bearer, {:header, name} or {:query, name}."}
    end
  end

  defp place?(:bearer), do: true
  defp place?({where, name}) when where in [:header, :query] and is_binary(name), do: true
  defp place?(_other), do: false

  defp schemes(spec, auth) do
    names = Map.keys(auth)

    case Enum.reject(names, &Map.has_key?(spec.schemes, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         "auth names #{Enum.join(unknown, ", ")}, which the description doesn't. It has #{known(spec)}."}
    end
  end

  defp known(%Spec{schemes: schemes}) when map_size(schemes) == 0, do: "none"

  defp known(%Spec{schemes: schemes}) do
    schemes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp offered(spec, opts) do
    signed = Enum.filter(spec.operations, &match?({:ok, _schemes}, signed(opts[:auth], &1)))
    exact = Enum.reject(opts[:only], &String.contains?(&1, "*"))

    # A glob leaves out what its names would be too long for; a name given exactly is an error.
    offered =
      Enum.filter(signed, fn operation ->
        operation.name in exact or
          (listed?(opts[:only], operation.name) and fits?(opts[:name], operation))
      end)

    with :ok <- named(opts[:only], spec, signed),
         :ok <- short(opts[:name], offered),
         do: {:ok, offered}
  end

  defp fits?(prefix, operation) do
    name = tool_name(prefix, operation)
    String.length(name) <= @name_limit
  end

  defp named(only, spec, signed) do
    exact = Enum.reject(only, &String.contains?(&1, "*"))
    missing = exact -- Enum.map(spec.operations, & &1.name)
    unsigned = (exact -- missing) -- Enum.map(signed, & &1.name)

    cond do
      missing != [] ->
        {:error, "The description has no operation #{Enum.join(missing, ", ")}."}

      unsigned != [] ->
        {:error,
         "auth gives no way to sign in to #{Enum.join(unsigned, ", ")}. Each needs #{needs(spec, unsigned)}."}

      true ->
        :ok
    end
  end

  defp needs(spec, names) do
    spec.operations
    |> Enum.filter(&(&1.name in names))
    |> Enum.flat_map(& &1.security)
    |> Enum.uniq()
    |> case do
      [] -> "a scheme wardrik_rest can't send"
      needed -> Enum.map_join(needed, " or ", &Enum.join(&1, " and "))
    end
  end

  defp short(prefix, operations) do
    case Enum.reject(operations, &fits?(prefix, &1)) do
      [] ->
        :ok

      long ->
        {:error,
         "These tool names would be over #{@name_limit} characters; use a shorter name: #{Enum.map_join(long, ", ", & &1.name)}."}
    end
  end

  @doc "Returns the name of `operation`'s tool, as `ga4__properties_runReport`."
  @spec tool_name(String.t(), Operation.t()) :: String.t()
  def tool_name(prefix, %Operation{name: name}), do: "#{prefix}__#{name}"

  defp listed?(globs, name), do: Enum.any?(globs, &glob?(&1, name))

  defp glob?(glob, name) do
    pattern =
      glob
      |> String.split("*")
      |> Enum.map_join(".*", &Regex.escape/1)

    Regex.match?(~r/\A#{pattern}\z/, name)
  end
end
