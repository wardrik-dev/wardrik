defmodule Tars.Test.SearchTool do
  @moduledoc """
  A `Tars.Tool` that answers searches from canned passages.

  Stands in for a real search pack wherever a test needs an agent whose tools
  reach the outside world, with no provider and no network.
  """

  @behaviour Tars.Tool

  alias Tars.Tool.Result

  @passages [
    %{
      "url" => "https://example.test/state",
      "title" => "The state of the thing",
      "text" => "Adoption roughly tripled over the last year, from a small base."
    },
    %{
      "url" => "https://example.test/players",
      "title" => "Who is building it",
      "text" => "Three vendors ship implementations; two of them are open source."
    }
  ]

  @impl true
  def tool do
    ReqLLM.Tool.new!(
      name: "web_search",
      description: "Search the web and get back passages from the pages found.",
      parameter_schema: [
        query: [type: :string, required: true, doc: "What you want to know"]
      ],
      callback: {__MODULE__, :run}
    )
  end

  @doc "Answers any query with the same passages."
  @spec run(map() | keyword()) :: Result.t()
  def run(params) do
    params = Map.new(params)

    Result.ok(%{"query" => Map.get(params, :query), "passages" => @passages})
  end
end
