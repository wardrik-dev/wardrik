defmodule WardrikACP.Harness do
  @options NimbleOptions.new!(
             command: [type: :string, required: true, doc: "The executable, found on `PATH`."],
             args: [type: {:list, :string}, default: [], doc: "Arguments for the command."],
             env: [
               type: {:map, :string, :string},
               default: %{},
               doc: "Environment variables for the command."
             ],
             meta: [
               type: {:map, :string, :any},
               default: %{},
               doc: "Sent as `_meta` when a session starts."
             ],
             options: [
               type: {:map, :string, {:or, [:string, :boolean]}},
               default: %{},
               doc:
                 "Session config options to set, by category or ID, such as `%{\"model\" => \"opus\"}`."
             ],
             instructions: [type: :string, doc: "Instructions for every session."],
             context: [
               type: {:list, :string},
               default: [],
               doc: "Files in the checkout added to the instructions, when present."
             ],
             description: [type: :string, doc: "What the calling model reads about the tool."],
             timeout: [
               type: :pos_integer,
               default: :timer.minutes(30),
               doc: "Milliseconds a call may take."
             ],
             idle: [
               type: :pos_integer,
               default: :timer.minutes(15),
               doc: "Milliseconds the process runs with no call attached. It then stops."
             ]
           )

  @moduledoc """
  A coding agent that `WardrikACP` starts over ACP, such as Claude Code.

      claude: [
        command: "claude-agent-acp",
        env: %{"ANTHROPIC_API_KEY" => System.fetch_env!("ANTHROPIC_API_KEY")},
        meta: %{"claudeCode" => %{"options" => %{"settingSources" => []}}},
        options: %{"mode" => "default"},
        context: ["CLAUDE.md", "AGENTS.md"]
      ]

    * The command receives its `env` plus `HOME`, `PATH` and a few other basics, not your app's
      whole environment.
    * The command runs in the worktree. It reads and writes files there itself.
    * `meta` and `options` are specific to each coding agent. Check its ACP docs for the ones that
      make it ask before it acts.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @enforce_keys [:name, :command]
  defstruct [
    :name,
    :command,
    :instructions,
    :description,
    args: [],
    env: %{},
    meta: %{},
    options: %{},
    context: [],
    timeout: :timer.minutes(30),
    idle: :timer.minutes(15)
  ]

  @type t() :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          meta: map(),
          options: %{String.t() => String.t() | boolean()},
          instructions: String.t() | nil,
          context: [String.t()],
          description: String.t() | nil,
          timeout: pos_integer(),
          idle: pos_integer()
        }

  @doc "Builds a harness named `name`. Raises if an option is invalid."
  @spec new!(atom() | String.t(), keyword()) :: t()
  def new!(name, opts) do
    opts = NimbleOptions.validate!(opts, @options)
    struct!(__MODULE__, [name: to_string(name)] ++ opts)
  end
end
