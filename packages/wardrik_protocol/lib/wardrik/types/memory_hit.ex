defmodule Wardrik.MemoryHit do
  @moduledoc """
  A file in an agent's workspace that answers a memory search, with its best passage.

      {:ok, hits} = Wardrik.Agent.memory_search(scope, "agt_1", query: "pumpkin loaf launch")
      #=> {:ok, [%Wardrik.MemoryHit{path: "digests/C1.md", line: 12, excerpt: "...", ...}]}

    * `:path` - its path in the workspace.
    * `:line` - the line its best passage starts on.
    * `:excerpt` - its best passage, cut to 600 bytes.
    * `:at` - when it was last written.
    * `:score` - how well it answers the query. Only the order means anything.
  """

  use Wardrik.Type,
    schema: ["memory_hits", "properties", "hits", "items"],
    fields: [
      path: "path",
      line: "line",
      excerpt: "excerpt",
      at: {"at", :datetime},
      score: "score"
    ]
end
