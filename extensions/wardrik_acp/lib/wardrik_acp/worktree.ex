defmodule WardrikACP.Worktree do
  @moduledoc false

  alias WardrikACP.Checkout

  @enforce_keys [:checkout, :path, :branch]
  defstruct [:checkout, :path, :branch]

  @type t() :: %__MODULE__{checkout: Checkout.t(), path: Path.t(), branch: String.t()}

  @doc "Adds the worktree on its branch, unless it's there. A new branch starts at the checkout's base."
  @spec open(t()) :: :ok | {:error, String.t()}
  def open(%__MODULE__{checkout: checkout} = worktree) do
    with :ok <- repository(checkout.path) do
      if File.dir?(worktree.path), do: :ok, else: add(worktree)
    end
  end

  @doc "Returns the branch, its head, and its commits since it left the checkout's base, oldest first."
  @spec report(t()) :: map()
  def report(%__MODULE__{checkout: checkout} = worktree) do
    head = git!(worktree.path, ["rev-parse", "HEAD"])

    base =
      git!(worktree.path, ["merge-base", head, git!(checkout.path, ["rev-parse", checkout.base])])

    %{
      "branch" => worktree.branch,
      "worktree" => worktree.path,
      "head" => head,
      "commits" => commits(worktree.path, base, head)
    }
  end

  @doc "Returns the checkout's worktrees in `dir`, each on its branch."
  @spec list(Checkout.t(), Path.t()) :: [t()]
  def list(%Checkout{} = checkout, dir) do
    checkout.path
    |> git!(["worktree", "list", "--porcelain"])
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(&listed(&1, checkout, dir <> "/"))
  end

  defp listed(block, checkout, dir) do
    with ["worktree " <> path | rest] <- String.split(block, "\n"),
         true <- String.starts_with?(path, dir),
         "branch refs/heads/" <> branch <-
           Enum.find(rest, "", &String.starts_with?(&1, "branch ")) do
      [%__MODULE__{checkout: checkout, path: path, branch: branch}]
    else
      _other -> []
    end
  end

  @doc """
  Returns whether merging the branch into the checkout's base would change nothing: its work is in
  the base, merged, squashed or cherry-picked.
  """
  @spec merged?(t()) :: boolean()
  def merged?(%__MODULE__{checkout: checkout, branch: branch}) do
    case git(checkout.path, ["merge-tree", "--write-tree", checkout.base, branch]) do
      {:ok, tree} -> tree == git!(checkout.path, ["rev-parse", checkout.base <> "^{tree}"])
      {:error, _conflicts} -> false
    end
  end

  @doc "Removes the worktree and its branch. A worktree with changes or untracked files stays."
  @spec remove(t()) :: :ok | {:error, String.t()}
  def remove(%__MODULE__{checkout: checkout} = worktree) do
    with {:ok, _output} <- git(checkout.path, ["worktree", "remove", worktree.path]),
         {:ok, _output} <- git(checkout.path, ["branch", "-D", worktree.branch]) do
      :ok
    end
  end

  @doc "Prunes what git knows of worktrees that are gone."
  @spec prune(Checkout.t()) :: :ok
  def prune(%Checkout{} = checkout) do
    git!(checkout.path, ["worktree", "prune"])
    :ok
  end

  @doc "Runs `git fetch` in the checkout, if it's set to."
  @spec fetch(Checkout.t()) :: :ok | {:error, String.t()}
  def fetch(%Checkout{fetch: false}), do: :ok

  def fetch(%Checkout{} = checkout) do
    case git(checkout.path, ["fetch", "--quiet"]) do
      {:ok, _output} -> :ok
      {:error, output} -> {:error, "git fetch failed in #{checkout.path}: #{output}"}
    end
  end

  defp commits(path, base, head) do
    path
    |> git!(["log", "--reverse", "--format=%H %s", "#{base}..#{head}"])
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [sha, subject] = String.split(line, " ", parts: 2)
      %{"sha" => sha, "subject" => subject}
    end)
  end

  defp repository(path) do
    case git(path, ["rev-parse", "--verify", "HEAD"]) do
      {:ok, _head} -> :ok
      {:error, _output} -> {:error, "#{path} isn't a git repository with a commit."}
    end
  end

  defp add(%__MODULE__{checkout: checkout} = worktree) do
    worktree.path
    |> Path.dirname()
    |> File.mkdir_p!()

    with :ok <- fetch(checkout) do
      args =
        if branch?(worktree),
          do: ["worktree", "add", worktree.path, worktree.branch],
          else: ["worktree", "add", "-b", worktree.branch, worktree.path, checkout.base]

      case git(checkout.path, args) do
        {:ok, _output} -> :ok
        {:error, output} -> {:error, "The worktree wasn't added: #{output}"}
      end
    end
  end

  defp branch?(worktree) do
    ref = "refs/heads/#{worktree.branch}"
    match?({:ok, _sha}, git(worktree.checkout.path, ["rev-parse", "--verify", "--quiet", ref]))
  end

  defp git!(dir, args) do
    {:ok, output} = git(dir, args)
    output
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
