defmodule Wardrik.AgentFile do
  @moduledoc """
  A file in an agent's workspace, without its content.

      {:ok, file, content} = Wardrik.Agent.file(scope, "agt_1", path: "skills/triage/SKILL.md")
      {:ok, file} =
        Wardrik.Agent.file_put(scope, "agt_1",
          path: file.path,
          content: content <> "\n",
          version: file.version
        )

    * `:path` - its path in the workspace.
    * `:version` - its version. `Wardrik.Agent.file_put/3` takes it to write over this version only.
    * `:bytes` - its size.
    * `:by` - who wrote it last: the agent's ID, or the ID of the person who wrote it.
    * `:at` - when it was last written.
    * `:labels` - labels of what the writer had read, such as `"outside"`.
  """

  use Wardrik.Type,
    schema: ["agent_file"],
    fields: [
      path: "path",
      version: "version",
      bytes: "bytes",
      by: "by",
      at: {"at", :datetime},
      labels: "labels"
    ]
end
