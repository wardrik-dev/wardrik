defmodule Wardrik.Trigger do
  @moduledoc """
  Asks an agent something without anyone typing. A trigger fires:

    * on a schedule: `every`, a cron expression or interval, in `timezone`.
    * once: `at`, a time in `timezone`. It's removed after it runs.
    * when one of its `feed` URLs has new entries.
    * when a service sends its `webhook` a request.
  """

  use Wardrik.Type,
    schema: ["trigger_definition"],
    fields: [
      name: "name",
      every: "every",
      at: "at",
      timezone: "timezone",
      prompt: "prompt",
      prompt_file: "prompt_file",
      overlap: {"overlap", [:skip, :queue, :settle]},
      missed: {"missed", [:run_once, :skip]},
      jitter: "jitter",
      feed: "feed",
      webhook: {"webhook", Wardrik.Trigger.Webhook},
      next_at: {"next_at", :datetime}
    ]
end

defmodule Wardrik.Trigger.Webhook do
  @moduledoc """
  A trigger's webhook. `secret` is a credential's name, as `${NAME}`. `verify` is `:shared` or
  `:standard`.
  """

  use Wardrik.Type,
    schema: ["trigger_definition", "properties", "webhook"],
    fields: [secret: "secret", verify: {"verify", [:shared, :standard]}]
end
