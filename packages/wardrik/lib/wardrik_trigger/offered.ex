defmodule WardrikTrigger.Offered do
  @moduledoc """
  The sources and webhook verifiers a deployment's triggers may name, each
  by its key: what this package ships, by default, and what a host offers
  beside it, which it hands to what reads triggers, as a
  `WardrikDefinition.Context`'s `triggers`, and to what delivers to them, as
  `WardrikTrigger.Deliveries`' `verifiers`:

      offered = %WardrikTrigger.Offered{}
      offered = %{offered | sources: Map.put(offered.sources, "watch", MyApp.Watch)}

      Wardrik.new(store: store, context: Wardrik.context(triggers: offered))
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
end
