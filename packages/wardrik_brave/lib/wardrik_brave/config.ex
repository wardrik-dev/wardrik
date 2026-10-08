defmodule WardrikBrave.Config do
  @moduledoc """
  Where a search goes, and with what key.

      WardrikBrave.Config.new(api_key: key)

  Options are `:api_key`, `:base_url`, `https://api.search.brave.com` unless
  given, and `:req_options`, merged into every request, which is the seam a
  test routes requests to a stub through so no socket is opened.

  `WardrikBrave.WebSearch` builds one for each call, with the key the call's
  credential resolved. A config with no key is a normal state: the client
  reports the missing key at call time.
  """

  defstruct [:base_url, :api_key, req_options: []]

  @type t() :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t() | nil,
          req_options: keyword()
        }

  @default_base_url "https://api.search.brave.com"

  @doc "Builds a config from `opts`, over the defaults."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, Keyword.merge([base_url: @default_base_url], opts))
  end

  @doc "Whether this config can actually reach Brave."
  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{api_key: key}), do: is_binary(key) and key != ""
end
