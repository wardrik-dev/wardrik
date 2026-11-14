defmodule WardrikDaemon.Ceiling.Reached do
  @moduledoc """
  The interrupt a model call waits on once its org's agents reach a ceiling's limit.

  An agent keeps it as `ceiling_reached`. See `Wardrik.Format`.
  """

  @behaviour Wardrik.Format

  defstruct interrupt: "ceiling_approval", message: nil, labels: []

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t(), labels: [String.t()]}

  @impl Wardrik.Format
  def type, do: "ceiling_reached"

  @impl Wardrik.Format
  def version, do: 1

  @impl Wardrik.Format
  def dump(%__MODULE__{} = reached),
    do: %{
      "interrupt" => reached.interrupt,
      "message" => reached.message,
      "labels" => reached.labels
    }

  @impl Wardrik.Format
  def load(1, %{"interrupt" => interrupt, "message" => message, "labels" => labels}),
    do: {:ok, %__MODULE__{interrupt: interrupt, message: message, labels: labels}}
end
