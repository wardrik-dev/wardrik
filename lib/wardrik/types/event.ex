defmodule Wardrik.Event do
  @moduledoc """
  One event, as a CloudEvent.

  `type` is like `"wardrik.run.completed"`. `data` follows the protocol's schema for that type.
  `agent` and `conversation` name the log it's in; `conversation` is `nil` for the agent's own.
  """

  use Wardrik.Type,
    schema: ["cloudevent"],
    fields: [
      id: "id",
      type: "type",
      source: "source",
      agent: "agent",
      conversation: "conversation",
      subject: "subject",
      time: {"time", :datetime},
      sequence: "sequence",
      data: "data",
      dataschema: "dataschema",
      datacontenttype: "datacontenttype",
      specversion: "specversion",
      traceparent: "traceparent",
      tracestate: "tracestate",
      parentspanid: "parentspanid"
    ]
end
