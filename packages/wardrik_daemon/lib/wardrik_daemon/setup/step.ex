defmodule WardrikDaemon.Setup.Step do
  @moduledoc """
  One part of `wardrik init`, such as offering Claude Code to agents.

  A step reads the machine, asks its questions, and answers the changes to make. It changes
  nothing itself: `WardrikDaemon.Setup.apply/2` makes the changes, in Wardrik's own directories
  alone.

      defmodule MyStep do
        @behaviour WardrikDaemon.Setup.Step

        @impl true
        def detect(machine), do: WardrikDaemon.Setup.Machine.executable(machine, "tool")

        @impl true
        def questions(nil), do: []

        def questions(_path),
          do: [%WardrikDaemon.Setup.Question{key: "tool.use", label: "Found tool. Use it?"}]

        @impl true
        def plan(path, %{"tool.use" => true}),
          do: [{:entry, "config.yaml", "tools", "tool", "command: \#{path}\\n"}]

        def plan(_path, _answers), do: []
      end
  """

  alias WardrikDaemon.Setup

  @typedoc "What a step found, which only the step reads."
  @type findings() :: term()

  @doc "Returns what the step finds on `machine`. It reads, and changes nothing."
  @callback detect(Setup.Machine.t()) :: findings()

  @doc "Returns the questions to ask about what was found. `[]` asks none."
  @callback questions(findings()) :: [Setup.Question.t()]

  @doc "Returns the changes to make, given what was found and the answers, by question key."
  @callback plan(findings(), %{String.t() => term()}) :: [Setup.change()]
end
