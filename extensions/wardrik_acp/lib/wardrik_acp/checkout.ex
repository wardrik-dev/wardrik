defmodule WardrikACP.Checkout do
  @options NimbleOptions.new!(
             path: [type: :string, required: true, doc: "The repository's directory."],
             base: [
               type: :string,
               default: "HEAD",
               doc: "The ref new branches start from, and the sweep compares with."
             ],
             fetch: [
               type: :boolean,
               default: false,
               doc: "`true` to run `git fetch` before a new branch starts and before each sweep."
             ]
           )

  @moduledoc """
  A git repository coding agents work in.

      checkouts: [
        billing: "/srv/billing",
        core: [path: "~/src/core", base: "origin/main", fetch: true]
      ]

    * A path alone is `[path: path]`.
    * The repository needs at least one commit.
    * With `base: "origin/main"` and `fetch: true`, new work starts from the remote's latest
      `main`, whatever branch the checkout is on.

  ## Options

  #{NimbleOptions.docs(@options)}
  """

  @enforce_keys [:name, :path]
  defstruct [:name, :path, base: "HEAD", fetch: false]

  @type t() :: %__MODULE__{name: String.t(), path: Path.t(), base: String.t(), fetch: boolean()}

  @doc "Builds the checkout `name` from a path or options. Raises if an option is invalid."
  @spec new!(atom() | String.t(), String.t() | keyword()) :: t()
  def new!(name, path) when is_binary(path), do: new!(name, path: path)

  def new!(name, opts) do
    opts = NimbleOptions.validate!(opts, @options)
    struct!(__MODULE__, [name: to_string(name)] ++ Keyword.update!(opts, :path, &Path.expand/1))
  end
end
