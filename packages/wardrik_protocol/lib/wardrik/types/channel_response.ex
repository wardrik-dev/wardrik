defmodule Wardrik.ChannelResponse do
  @moduledoc "A channel's response to its chat app: the `status`, `headers` and `body` to send unchanged."

  use Wardrik.Type,
    schema: ["channel_response"],
    fields: [status: "status", headers: "headers", body: "body"]
end
