defmodule WardrikRest do
  @moduledoc """
  Tools for agents from an HTTP API's description: one tool per operation, with the API's own
  sign-in and keys.

      {:ok, analytics} =
        WardrikRest.API.load(
          {WardrikRest.Discovery,
           url: "https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta"},
          name: "ga4",
          base_url: "https://analyticsdata.googleapis.com/",
          auth: %{"oauth2" => {:credential, "google"}},
          only: ["properties_runReport", "properties_getMetadata"],
          read_only: ["properties_runReport"]
        )

      WardrikCore.start_agent(
        agent_id: "agt_marketing",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikRest, apis: [analytics]}],
        credentials: {MyApp.Credentials, []}
      )

    * Each tool is named `<api>__<operation>`, as `ga4__properties_runReport`, and takes the
      operation's path, query and body arguments.
    * `GET`s and the operations given as `:read_only` are read-only; the rest need a person's
      approval unless the policy allows them.
    * Answers are labelled `"outside"` unless the API is `:trusted`.
    * A tool whose schema is over the API's `:max_schema_bytes` names its deeper types instead
      of listing their fields, and `<api>__describe` gives them.

  Descriptions are read by a `WardrikRest.Reader`. See `WardrikRest.Discovery` and
  `WardrikRest.API`.
  """

  @behaviour WardrikCore.Capability

  alias WardrikRest.API
  alias WardrikRest.Call

  @margin 1_000

  @impl WardrikCore.Capability
  def tools(_context, opts) do
    opts
    |> Keyword.fetch!(:apis)
    |> Enum.flat_map(fn api ->
      Enum.map(api.operations, &tool(api, &1)) ++ describing(api)
    end)
  end

  @doc "Returns the tool for `operation` of `api`."
  @spec tool(API.t(), WardrikRest.Operation.t()) :: WardrikCore.Tool.t()
  def tool(%API{} = api, operation) do
    annotations = API.annotations(api, operation)

    WardrikCore.Tool.new!(
      name: API.tool_name(api.name, operation),
      description: operation.description,
      schema: Map.fetch!(api.schemas, operation.name),
      run: fn args, context -> Call.run(api, operation, args, context) end,
      annotations:
        annotations ++
          [
            open_world: true,
            gated: not annotations[:read_only],
            timeout: api.timeout + @margin,
            labels: if(api.trusted, do: [], else: ["outside"])
          ]
    )
  end

  defp describing(%API{described: []}), do: []

  defp describing(%API{described: [example | _more]} = api) do
    [
      WardrikCore.Tool.new!(
        name: API.describe(api),
        description:
          "Gives the fields of an object #{api.name}'s tools name instead of listing, as #{example}.",
        schema: %{
          "type" => "object",
          "properties" => %{"type" => %{"type" => "string", "description" => "As #{example}."}},
          "required" => ["type"]
        },
        run: fn %{"type" => type}, _context -> described(api, type) end,
        annotations: [read_only: true, idempotent: true, gated: false, timeout: @margin]
      )
    ]
  end

  defp described(api, type) do
    tools =
      Map.new(api.operations, fn operation ->
        properties = Map.new(operation.parameters, &{&1.name, &1.schema})
        {API.tool_name(api.name, operation), %{"type" => "object", "properties" => properties}}
      end)

    case WardrikRest.Schema.describe(api.types, tools, type, API.describe(api)) do
      {:ok, schema} ->
        {:ok, schema}

      :error ->
        {:error,
         "#{api.name} has no type #{type}. Its tools name #{Enum.join(Enum.take(api.described, 20), ", ")}."}
    end
  end
end
