defmodule TarsNotify.Config do
  @moduledoc """
  Where `TarsNotify` gets its settings.

      config :tars, TarsNotify,
        targets: [
          ops: {TarsNotify.Slack, channel: "#ops", token: "xoxb-…", app_token: "xapp-…"},
          audit: {TarsNotify.Webhook, url: "https://hooks.example.com/tars"}
        ]

  `:targets` names each target and the module and options that deliver to
  it. `:req_options` is merged into every HTTP request the package makes,
  which is the seam a test routes them through.

  The daemon fills these in from `config.yaml`'s `notify` section; see
  `TarsDaemon.Config`.
  """

  @doc "Every target, by name."
  @spec targets() :: [{atom(), {module(), keyword()}}]
  def targets, do: Keyword.get(env(), :targets, [])

  @doc "The target named `name`, which may be given as its name's string."
  @spec target(atom() | String.t()) :: {:ok, {module(), keyword()}} | :error
  def target(name) when is_atom(name), do: Keyword.fetch(targets(), name)

  def target(name) when is_binary(name) do
    case Enum.find(targets(), fn {key, _target} -> Atom.to_string(key) == name end) do
      {_key, target} -> {:ok, target}
      nil -> :error
    end
  end

  @doc "Options merged into every request the package makes."
  @spec req_options() :: keyword()
  def req_options, do: Keyword.get(env(), :req_options, [])

  defp env, do: Application.get_env(:tars, TarsNotify, [])
end
