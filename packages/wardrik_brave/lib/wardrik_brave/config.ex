defmodule WardrikBrave.Config do
  @moduledoc """
  Where the Brave client gets its settings.

      config :wardrik_brave, WardrikBrave, api_key: System.fetch_env!("BRAVE_API_KEY")

  Options are `:api_key`, `:base_url`, and `:req_options`, and each can be
  overridden per call through `new/1`. `:req_options` is merged into every
  request, which is the seam a test injects a transport through so no socket is
  opened.

  The key is read rather than fetched: a build with no key is a normal state,
  and the client reports a missing key at call time rather than refusing to
  boot.
  """

  defstruct [:base_url, :api_key, req_options: []]

  @type t() :: %__MODULE__{
          base_url: String.t(),
          api_key: String.t() | nil,
          req_options: keyword()
        }

  @default_base_url "https://api.search.brave.com"

  @doc "Builds a config from application env, overridable per call."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    env = Application.get_env(:wardrik_brave, WardrikBrave, [])

    defaults = [
      api_key: Keyword.get(env, :api_key),
      base_url: Keyword.get(env, :base_url, @default_base_url),
      req_options: Keyword.get(env, :req_options, [])
    ]

    struct(__MODULE__, Keyword.merge(defaults, opts))
  end

  @doc "Whether this config can actually reach Brave."
  @spec usable?(t()) :: boolean()
  def usable?(%__MODULE__{api_key: key}), do: is_binary(key) and key != ""
end
