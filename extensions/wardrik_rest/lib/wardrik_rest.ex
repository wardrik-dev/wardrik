defmodule WardrikRest do
  @moduledoc """
  Tools for agents from an HTTP API's description: one tool per operation, with the API's own
  sign-in and keys.

      {:ok, discovery} =
        WardrikRest.Discovery.fetch("https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta")

      {:ok, analytics} =
        WardrikRest.API.load(discovery,
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

  Descriptions are read by a `WardrikRest.Reader`. See `WardrikRest.Discovery` and
  `WardrikRest.API`.
  """

  @behaviour WardrikCore.Capability

  alias WardrikRest.API
  alias WardrikRest.Call

  @margin 1_000

  @impl WardrikCore.Capability
  def tools(_context, opts) do
    for api <- Keyword.fetch!(opts, :apis), operation <- api.operations, do: tool(api, operation)
  end

  @doc "Returns the tool for `operation` of `api`."
  @spec tool(API.t(), WardrikRest.Operation.t()) :: WardrikCore.Tool.t()
  def tool(%API{} = api, operation) do
    annotations = API.annotations(api, operation)

    WardrikCore.Tool.new!(
      name: API.tool_name(api.name, operation),
      description: operation.description,
      schema: schema(operation),
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

  defp schema(operation) do
    required = for %{required: true, name: name} <- operation.parameters, do: name

    %{
      "type" => "object",
      "properties" => Map.new(operation.parameters, &{&1.name, &1.schema})
    }
    |> Map.merge(if required == [], do: %{}, else: %{"required" => Enum.sort(required)})
  end
end
