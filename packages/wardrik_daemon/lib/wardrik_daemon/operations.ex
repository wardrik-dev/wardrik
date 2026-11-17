defmodule WardrikDaemon.Operations do
  @moduledoc """
  The daemon's own operations, as `priv/openapi.json` describes them, run for a caller. Its HTTP
  routes and its MCP tools both run them.

      operations = WardrikDaemon.Operations.new(daemon, scope)
      {:ok, %{"tokens" => _tokens}} = WardrikDaemon.Operations.run(operations, "tokens.list", %{})

  Each takes one input: its path and query parameters and its body, together. It's checked
  against the operation's schema, then the caller is checked, as each route's description says.
  """

  alias Wardrik.Error
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Ceiling
  alias WardrikDaemon.Connections
  alias WardrikDaemon.CreateAgent
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Tokens

  @enforce_keys [:daemon, :scope]
  defstruct @enforce_keys

  @typedoc "The daemon, as `WardrikDaemon.HTTP` holds it, and the scope its caller acts in."
  @type t() :: %__MODULE__{daemon: map(), scope: Wardrik.Scope.t()}

  @typedoc """
  An operation: its `:id`, `:summary`, `:description`, `:effect`, HTTP `:method`, `:path`,
  `:parameters`, success `:status`, whether it takes a `:body` (`:required`, `:optional` or
  `:none`), and one `:input` schema for its parameters and body.
  """
  @type operation() :: %{
          id: String.t(),
          summary: String.t(),
          description: String.t(),
          effect: String.t(),
          method: String.t(),
          path: String.t(),
          parameters: [%{name: String.t(), in: String.t()}],
          status: pos_integer(),
          body: :required | :optional | :none,
          input: map()
        }

  @openapi_path Application.app_dir(:wardrik_daemon, "priv/openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path
           |> File.read!()
           |> JSON.decode!()

  # A definition goes beside an agent's name, so its keys are the agent's input too.
  @definition "agent.define"
              |> WardrikProtocol.operation()
              |> get_in([:input, "properties"])
              |> Map.delete("agent")

  local = fn local, document, value ->
    case value do
      %{"$ref" => "#/" <> pointer} ->
        local.(local, document, get_in(document, String.split(pointer, "/")))

      %{} = map ->
        Map.new(map, fn {key, value} -> {key, local.(local, document, value)} end)

      list when is_list(list) ->
        Enum.map(list, &local.(local, document, &1))

      value ->
        value
    end
  end

  @operations (for {path, methods} <- @openapi["paths"],
                   {method, operation} <- methods,
                   into: %{} do
                 operation = local.(local, @openapi, operation)
                 parameters = operation["parameters"] || []

                 body =
                   get_in(operation, ["requestBody", "content", "application/json", "schema"])

                 input =
                   Enum.reduce(
                     parameters,
                     body || %{"type" => "object", "additionalProperties" => false},
                     fn parameter, input ->
                       schema =
                         Map.put_new(parameter["schema"], "description", parameter["description"])

                       input
                       |> Map.update(
                         "properties",
                         %{parameter["name"] => schema},
                         &Map.put(&1, parameter["name"], schema)
                       )
                       |> then(fn input ->
                         if parameter["required"],
                           do:
                             Map.update(
                               input,
                               "required",
                               [parameter["name"]],
                               &[parameter["name"] | &1]
                             ),
                           else: input
                       end)
                     end
                   )

                 input =
                   if operation["operationId"] == "agents.create",
                     do: Map.update!(input, "properties", &Map.merge(@definition, &1)),
                     else: input

                 {status, _response} =
                   Enum.find(operation["responses"], fn {status, _response} -> status < "300" end)

                 {operation["operationId"],
                  %{
                    id: operation["operationId"],
                    summary: operation["summary"],
                    description: operation["description"],
                    effect: operation["x-wardrik-effect"],
                    method: method,
                    path: path,
                    parameters: Enum.map(parameters, &%{name: &1["name"], in: &1["in"]}),
                    status: String.to_integer(status),
                    body:
                      cond do
                        body == nil -> :none
                        operation["requestBody"]["required"] -> :required
                        true -> :optional
                      end,
                    input: input
                  }}
               end)

  @inputs Map.new(@operations, fn {id, operation} -> {id, JSV.build!(operation.input)} end)

  @doc "Returns the daemon's operations for `daemon`, run in `scope`."
  @spec new(map(), Wardrik.Scope.t()) :: t()
  def new(daemon, scope), do: %__MODULE__{daemon: daemon, scope: scope}

  @doc "Returns every operation."
  @spec list() :: [operation()]
  def list, do: Map.values(@operations)

  @doc "Returns the operation `id`, or `nil`."
  @spec get(String.t()) :: operation() | nil
  def get(id), do: Map.get(@operations, id)

  @doc "Returns a `Wardrik.HTTP.MCP.Tool` for each operation."
  @spec build_tools(t()) :: [Wardrik.HTTP.MCP.Tool.t()]
  def build_tools(%__MODULE__{} = operations) do
    for {id, operation} <- @operations,
        do: Wardrik.HTTP.MCP.Tool.new(operation, &run(operations, id, &1))
  end

  @doc "Runs the operation `id` with `input`. Returns its output, `nil` for none."
  @spec run(t(), String.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def run(%__MODULE__{} = operations, id, input) do
    with {:ok, input} <- validate_input(id, input), do: perform(operations, id, input)
  end

  defp validate_input(id, input) do
    case JSV.validate(input, Map.fetch!(@inputs, id)) do
      {:ok, input} -> {:ok, input}
      {:error, error} -> {:error, Error.new(:invalid_request, Exception.message(error))}
    end
  end

  # Each agent is listed only where the caller may read it, so they learn of no other.
  defp perform(%{daemon: daemon, scope: scope}, "agents.find", %{"owner" => owner} = input) do
    with :ok <- Allowed.named(owner),
         :ok <- Allowed.kept(owner, daemon.orgs) do
      agents =
        for record <- AgentRecords.in_org(daemon.store, Owners.org(owner)),
            input["name"] in [nil, record.name],
            match?({:ok, _read}, Wardrik.run(scope, "agent.read", %{"agent" => record.id})),
            do: encode_record(record)

      {:ok, %{"agents" => agents}}
    end
  end

  defp perform(%{daemon: daemon, scope: scope}, "agents.create", %{"owner" => owner} = input) do
    with :ok <- Allowed.owned(daemon, scope, owner, {"agent.create", :agents}),
         {:ok, record} <- CreateAgent.create(daemon, scope, {owner, Map.delete(input, "owner")}),
         do: {:ok, encode_record(record)}
  end

  defp perform(%{daemon: daemon, scope: scope}, "ceilings.list", %{"owner" => owner}) do
    with :ok <- Allowed.owned(daemon, scope, owner, {"ceiling.read", :ceiling}),
         {:ok, ceilings} <- Ceiling.list(daemon, owner),
         do: {:ok, %{"ceilings" => ceilings}}
  end

  # A caller's connections are their own, as the principal their token acts as.
  defp perform(%{daemon: daemon, scope: scope}, "connections.pair", input) do
    %{"provider" => provider, "code" => code} = input

    with :ok <- Allowed.authorized(scope, "connection.connect", {:connection, scope.principal.id}),
         do: Connections.pair(daemon, scope.principal, {provider, code})
  end

  defp perform(%{daemon: daemon, scope: scope}, "tokens.list", _input) do
    with :ok <- Allowed.authorized(scope, "token.read", {:token, "*"}) do
      tokens =
        daemon.store
        |> Tokens.list()
        |> Enum.map(&Tokens.json/1)

      {:ok, %{"tokens" => tokens}}
    end
  end

  # The subject is checked as the resource, so a rule's names can say whom a token may act as.
  defp perform(%{daemon: daemon, scope: scope}, "tokens.create", input) do
    with :ok <- Allowed.authorized(scope, "token.create", {:token, input["subject"]}),
         do: Tokens.issue(daemon.store, input)
  end

  defp perform(%{daemon: daemon, scope: scope}, "tokens.revoke", %{"id" => id}) do
    with :ok <- Allowed.authorized(scope, "token.delete", {:token, id}),
         :ok <- Tokens.revoke(daemon.store, id),
         do: {:ok, nil}
  end

  defp perform(%{daemon: daemon, scope: scope}, "tokens.web", input) do
    with {:ok, url} <- WardrikDaemon.Web.sign_in(daemon, scope, agent: input["agent"]),
         do: {:ok, %{"url" => url}}
  end

  defp encode_record(record),
    do: %{"id" => record.id, "name" => record.name, "org" => record.org, "owner" => record.owner}
end
