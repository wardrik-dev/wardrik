defmodule WardrikRest.API do
  alias WardrikRest.Operation
  alias WardrikRest.Reader
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
            headers: [
              type: {:map, :string, :any},
              default: %{},
              doc:
                "Headers every call sends that the description doesn't name, each a source, as `%{\"developer-token\" => {:key, \"ADS_TOKEN\"}}`."
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
    :idempotent
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
    trusted: false,
    timeout: 30_000,
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
          trusted: boolean(),
          timeout: pos_integer(),
          req_options: keyword()
        }

  @doc """
  Reads `source` with `WardrikRest.Reader` and keeps the operations `opts` offer.

  Returns `{:error, reason}` if the description can't be read, `:base_url` fails `:egress`,
  `:auth` names a scheme the description doesn't, or `:only` names an operation it doesn't have,
  can't sign in to, or whose tool name would be over 64 characters.
  """
  @spec load(Reader.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(source, opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    with {:ok, spec} <- Reader.read(source),
         :ok <- opts[:egress].(opts[:base_url]),
         :ok <- schemes(spec, opts[:auth]),
         {:ok, operations} <- offered(spec, opts) do
      {:ok,
       %__MODULE__{
         name: opts[:name],
         base_url: String.trim_trailing(opts[:base_url], "/") <> "/",
         operations: operations,
         schemes: spec.schemes,
         auth: opts[:auth],
         headers: opts[:headers],
         read_only: opts[:read_only],
         idempotent: opts[:idempotent],
         trusted: opts[:trusted],
         timeout: opts[:timeout],
         req_options: opts[:req_options]
       }}
    end
  end

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

  defp schemes(spec, auth) do
    case Enum.reject(Map.keys(auth), &Map.has_key?(spec.schemes, &1)) do
      [] ->
        :ok

      unknown ->
        {:error,
         "auth names #{Enum.join(unknown, ", ")}, which the description doesn't. It has #{known(spec)}."}
    end
  end

  defp known(%Spec{schemes: schemes}) when map_size(schemes) == 0, do: "none"
  defp known(%Spec{schemes: schemes}), do: schemes |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp offered(spec, opts) do
    signed = Enum.filter(spec.operations, &match?({:ok, _schemes}, signed(opts[:auth], &1)))
    offered = Enum.filter(signed, &listed?(opts[:only], &1.name))

    with :ok <- named(opts[:only], spec, signed),
         :ok <- short(opts[:name], offered),
         do: {:ok, offered}
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
    |> Enum.map_join(" or ", &Enum.join(&1, " and "))
  end

  defp short(prefix, operations) do
    case Enum.filter(operations, &(String.length(tool_name(prefix, &1)) > @name_limit)) do
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
    pattern = glob |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.match?(~r/\A#{pattern}\z/, name)
  end
end
