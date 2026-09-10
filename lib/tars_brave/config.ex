defmodule TarsBrave.Config do
  @moduledoc """
  Where the Brave client gets its settings.

      config :tars, TarsBrave, api_key: System.fetch_env!("BRAVE_API_KEY")

  Options are `:api_key`, `:base_url`, and `:req_options`, and each can be
  overridden per call through `new/1`. `:req_options` is merged into every
  request, which is the seam a test injects a transport through so no socket is
  opened.

  The key is read rather than fetched: a build with no key is a normal state,
  and the client reports a missing key at call time rather than refusing to
  boot.

  ## Why the key is nested under `:tars`

  This package is not yet its own OTP application, so `config :tars_brave` would
  configure something that does not exist and Mix says so on every run. Nesting
  it under the application that does exist keeps the setting real.

  ## Extracting this package

  When Brave moves out into `tars_brave`, three things change and nothing else:

    1. `lib/tars_brave/` and `test/tars_brave/` move into the new project, which
       declares `{:req, "~> 0.7"}` itself.
    2. Tars depends on it, first as `{:tars_brave, path: "tools/tars_brave"}`
       and later as a version.
    3. The setting becomes `config :tars_brave, api_key: ...`, and `new/1` reads
       `Application.get_env(:tars_brave, :api_key)` instead of the nested key.

  Nothing in `Tars` itself is touched, because core names no tool. Only a
  config naming `TarsBrave.WebSearch` does.
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
    env = Application.get_env(:tars, TarsBrave, [])

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
