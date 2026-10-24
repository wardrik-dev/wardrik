defmodule Wardrik.ChannelResponse do
  @moduledoc "What a channel answers its chat app: the `status`, `headers` and `body` to send as they are."

  use Wardrik.Type,
    schema: ["channel_response"],
    fields: [status: "status", headers: "headers", body: "body"]
end
