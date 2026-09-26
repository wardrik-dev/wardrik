defmodule TarsDemo do
  @moduledoc """
  A policy and three tools for driving the governance seams by hand.

  Compiled in `:dev` only, so nothing here ships. It exists to make the states
  a `Tars.Hook` can put a turn into reachable from a terminal:

      mix tars --policy TarsDemo.Policy --user jon --org acme \\
        --tool TarsDemo.ListServices --tool TarsDemo.Deploy --tool TarsDemo.DropTable

  Ask it to list the services and it answers. Ask it to deploy one and the turn
  parks. Ask it to drop a table and it is refused and says so.

  Resume a parked turn from anywhere that can reach the node:

      Tars.Agent.resume(:tars_tui, %{"call_1" => :approve})
      Tars.Agent.resume(:tars_tui, %{"call_1" => {:deny, "Not during the freeze."}})
  """

  defmodule Policy do
    @moduledoc """
    Reads a call and decides, with no access to any credential.

    Three rules, one per answer a hook can give: reading is free, deploying
    needs a person, and dropping a table is refused outright.
    """

    @behaviour Tars.Hook

    import Tars.Call

    alias Tars.Call.Tool

    @impl true
    def init(_opts), do: nil

    @impl true
    def call(%Tars.Call{target: %Tool{name: "deploy", arguments: args}} = call, _value) do
      ask(
        call,
        "Deploy #{args["service"]} to #{args["environment"]}, asked for by #{who(call.scope)}?"
      )
    end

    def call(%Tars.Call{target: %Tool{name: "drop_table", arguments: args}} = call, _value),
      do: deny(call, "Dropping #{args["table"]} is not something an agent may do. Ask a DBA.")

    def call(%Tars.Call{target: %Tool{name: "restart_service", arguments: args}} = call, _value),
      do: deny(call, "Restarting #{args["service"]} is owned by the platform team. Open a ticket.")

    def call(call, _value), do: call

    defp who(%{user: nil, org: nil}), do: "nobody in particular"
    defp who(%{user: nil, org: org}), do: org
    defp who(%{user: user, org: nil}), do: user
    defp who(%{user: user, org: org}), do: "#{user} of #{org}"
  end

  defmodule ListServices do
    @moduledoc "A read-only tool, to show that a policy in place costs an allowed call nothing."

    @behaviour Tars.Tool

    @services ["billing", "checkout", "search"]

    @impl true
    def tool do
      ReqLLM.Tool.new!(
        name: "list_services",
        description: "List the services that can be deployed.",
        parameter_schema: [],
        callback: {__MODULE__, :run}
      )
    end

    @doc false
    def run(_args), do: Tars.Tool.Result.ok(%{"services" => @services})
  end

  defmodule Deploy do
    @moduledoc """
    The tool the demo policy asks about.

    It reports the call id it ran under, which is the id a person approved, so
    a run can be followed from the approval to the effect.
    """

    @behaviour Tars.Tool

    @impl true
    def tool do
      Tars.Tool.new!(
        name: "deploy",
        description: "Deploy a service to an environment. This has a real effect.",
        parameter_schema: [
          service: [type: :string, required: true, doc: "Which service to deploy"],
          environment: [type: :string, required: true, doc: "Where to deploy it"]
        ],
        call: {__MODULE__, :run}
      )
    end

    @doc false
    def run(%Tars.Call{id: id, target: %{arguments: args}} = call) do
      Tars.Call.answer(
        call,
        Tars.Tool.Result.ok(%{
          "deployed" => args.service,
          "environment" => args.environment,
          "approved_call" => id
        })
      )
    end
  end

  defmodule RestartService do
    @moduledoc """
    A tool the policy refuses, and that a model has no reason to refuse itself.

    `DropTable` turns out to be a poor way to exercise a refusal, because a
    capable model declines to call it before any policy is consulted. This one
    is unremarkable enough to be called, which is what makes the refusal
    visible.
    """

    @behaviour Tars.Tool

    @impl true
    def tool do
      ReqLLM.Tool.new!(
        name: "restart_service",
        description: "Restart a running service.",
        parameter_schema: [service: [type: :string, required: true, doc: "Which service"]],
        callback: {__MODULE__, :run}
      )
    end

    @doc false
    def run(%{service: service}) do
      raise "restart_service ran for #{service}, which means the hook did not stop it"
    end
  end

  defmodule DropTable do
    @moduledoc "The tool the demo policy refuses. Its callback must never run."

    @behaviour Tars.Tool

    @impl true
    def tool do
      ReqLLM.Tool.new!(
        name: "drop_table",
        description: "Drop a database table permanently.",
        parameter_schema: [table: [type: :string, required: true, doc: "The table to drop"]],
        callback: {__MODULE__, :run}
      )
    end

    @doc false
    def run(%{table: table}) do
      raise "drop_table ran for #{table}, which means the hook did not stop it"
    end
  end
end
