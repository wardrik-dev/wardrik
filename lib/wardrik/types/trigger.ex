defmodule Wardrik.Trigger do
  @moduledoc """
  A trigger asks an agent something without anyone typing: `every` cron expression or interval,
  read in `timezone`, when one of its `feed` URLs has new entries, or when a service sends its
  `webhook` a request. See the Trigger agents guide.
  """

  use Wardrik.Type,
    schema: ["trigger_definition"],
    fields: [
      name: "name",
      every: "every",
      timezone: "timezone",
      prompt: "prompt",
      prompt_file: "prompt_file",
      overlap: {"overlap", [:skip, :queue]},
      missed: {"missed", [:run_once, :skip]},
      jitter: "jitter",
      feed: "feed",
      webhook: {"webhook", Wardrik.Trigger.Webhook}
    ]
end

defmodule Wardrik.Trigger.Webhook do
  @moduledoc """
  Where a service sends a trigger requests: the `secret` it holds, as `${NAME}`, and how a request
  proves it, `:shared` or `:standard`.
  """

  use Wardrik.Type,
    schema: ["trigger_definition", "properties", "webhook"],
    fields: [secret: "secret", verify: {"verify", [:shared, :standard]}]
end
