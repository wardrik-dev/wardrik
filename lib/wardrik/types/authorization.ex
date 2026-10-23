defmodule Wardrik.Authorization do
  @moduledoc "Where a person signs in for a call that waits on it: the `url`, and the `code` a device sign-in shows."

  use Wardrik.Type, schema: ["authorization"], fields: [url: "url", code: "code"]
end
