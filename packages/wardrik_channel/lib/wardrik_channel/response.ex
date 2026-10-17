defmodule WardrikChannel.Response do
  @moduledoc """
  What a channel answers a request with, for the host to send back as it
  is: a status, headers and a body.
  """

  @enforce_keys [:status]
  defstruct [:status, headers: [], body: ""]

  @type t() :: %__MODULE__{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: iodata()
        }

  @doc "An answer of `status` saying `text`, as plain text."
  @spec text(pos_integer(), String.t()) :: t()
  def text(status, text),
    do: %__MODULE__{
      status: status,
      headers: [{"content-type", "text/plain; charset=utf-8"}],
      body: text
    }

  @doc "An answer of `status` with `body` as JSON."
  @spec json(pos_integer(), term()) :: t()
  def json(status, body),
    do: %__MODULE__{
      status: status,
      headers: [{"content-type", "application/json"}],
      body: JSON.encode!(body)
    }

  @doc "An answer sending the browser to `url`."
  @spec redirect(String.t()) :: t()
  def redirect(url), do: %__MODULE__{status: 302, headers: [{"location", url}]}
end
