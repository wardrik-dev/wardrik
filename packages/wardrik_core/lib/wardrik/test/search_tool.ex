defmodule Wardrik.Test.SearchTool do
  @moduledoc """
  A `Wardrik.Tool` that answers searches from canned passages.

  Stands in for a real search pack wherever a test needs an agent whose tools
  reach the outside world, with no provider and no network.
  """

  @behaviour Wardrik.Tool

  alias Wardrik.Tool.Result

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
    Wardrik.Tool.new!(
      name: "web_search",
      description: "Search the web and get back passages from the pages found.",
      schema: [
        query: [type: :string, required: true, doc: "What you want to know"]
      ],
      run: {__MODULE__, :run, []}
    )
  end

  @doc "Answers any query with the same passages."
  @spec run(map() | keyword(), Wardrik.Tool.Context.t()) :: Result.t()
  def run(params, _context) do
    params = Map.new(params)

    Result.ok(%{"query" => Map.get(params, :query), "passages" => @passages})
  end
end
