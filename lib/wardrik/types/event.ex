defmodule Wardrik.Event do
  @moduledoc """
  One event, as a CloudEvent: its `type`, like `"wardrik.run.completed"`, what it's about, and its
  `data`, as the protocol's schema for its type describes it.
  """

  use Wardrik.Type,
    schema: ["cloudevent"],
    fields: [
      id: "id",
      type: "type",
      source: "source",
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
