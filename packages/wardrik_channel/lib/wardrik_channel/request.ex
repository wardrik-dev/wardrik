defmodule WardrikChannel.Request do
  @moduledoc """
  A request the medium sent a channel over HTTP, as the host that serves it
  received it, handed to `WardrikChannel.request/2`:

    * `:method` - `"POST"`, say
    * `:path` - the path below the channel's own, in segments: `["events"]`
      for a request to `/channels/slack/events`
    * `:query` - the query string's parameters
    * `:headers` - each header, its name in lower case, as Plug has them
    * `:body` - the body as it was sent, not parsed, since a signature is
      over its bytes
  """

  @enforce_keys [:method, :path, :headers, :body]
  defstruct [:method, :path, :headers, :body, query: %{}]

  @type t() :: %__MODULE__{
          method: String.t(),
          path: [String.t()],
          query: %{String.t() => String.t()},
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc "The value of the header `name`, in lower case, where it was sent."
  @spec header(t(), String.t()) :: String.t() | nil
  def header(%__MODULE__{headers: headers}, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end
end
