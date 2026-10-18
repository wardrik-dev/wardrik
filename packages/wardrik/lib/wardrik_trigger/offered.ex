defmodule WardrikTrigger.Offered do
  @moduledoc """
  The sources and webhook verifiers a deployment's triggers may name, each
  by its key: what this package ships, and what `discover/0` finds the
  loaded applications register, which a host reads once as it starts and
  hands to what reads triggers and delivers to them.

  A package registers a source or a verifier in its application's
  environment:

      def application,
        do: [env: [wardrik_trigger_sources: [watch: MyApp.Watch]]]

      def application,
        do: [env: [wardrik_trigger_verifiers: [acme_pay: MyApp.AcmePaySignature]]]
  """

  defstruct sources: %{"feed" => WardrikTrigger.Feed},
            verifiers: %{
              "shared" => WardrikTrigger.Webhook.Shared,
              "standard" => WardrikTrigger.Webhook.Standard
            }

  @type t() :: %__MODULE__{
          sources: %{String.t() => module()},
          verifiers: %{String.t() => module()}
        }

  @doc """
  What this package ships, and every source and verifier the loaded
  applications register. Read once, as a host starts.
  """
  @spec discover() :: t()
  def discover do
    %__MODULE__{
      sources: registered(:wardrik_trigger_sources),
      verifiers: registered(:wardrik_trigger_verifiers)
    }
  end

  defp registered(key) do
    for {app, _description, _version} <- Application.loaded_applications(),
        {name, module} <- Application.get_env(app, key, []),
        into: %{},
        do: {to_string(name), module}
  end
end
