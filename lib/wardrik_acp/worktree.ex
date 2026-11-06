defmodule WardrikACP.Worktree do
  @moduledoc false

  @enforce_keys [:checkout, :path, :branch]
  defstruct [:checkout, :path, :branch]

  @type t() :: %__MODULE__{checkout: Path.t(), path: Path.t(), branch: String.t()}

  @doc "Adds the worktree on its branch, unless it's there. The branch starts at the checkout's HEAD."
  @spec open(t()) :: :ok | {:error, String.t()}
  def open(%__MODULE__{} = worktree) do
    with :ok <- repository(worktree.checkout) do
      if File.dir?(worktree.path), do: :ok, else: add(worktree)
    end
  end

  @doc "Returns the branch, its head, and its commits since it left the checkout's HEAD, oldest first."
  @spec report(t()) :: map()
  def report(%__MODULE__{} = worktree) do
    head = git!(worktree.path, ["rev-parse", "HEAD"])

    base =
      git!(worktree.path, ["merge-base", head, git!(worktree.checkout, ["rev-parse", "HEAD"])])

    %{
      "branch" => worktree.branch,
      "worktree" => worktree.path,
      "head" => head,
      "commits" => commits(worktree.path, base, head)
    }
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

  defp repository(checkout) do
    case git(checkout, ["rev-parse", "--verify", "HEAD"]) do
      {:ok, _head} -> :ok
      {:error, _output} -> {:error, "#{checkout} isn't a git repository with a commit."}
    end
  end

  defp add(worktree) do
    File.mkdir_p!(Path.dirname(worktree.path))

    args =
      if branch?(worktree),
        do: ["worktree", "add", worktree.path, worktree.branch],
        else: ["worktree", "add", "-b", worktree.branch, worktree.path, "HEAD"]

    case git(worktree.checkout, args) do
      {:ok, _output} -> :ok
      {:error, output} -> {:error, "The worktree wasn't added: #{output}"}
    end
  end

  defp branch?(worktree),
    do:
      match?(
        {:ok, _sha},
        git(worktree.checkout, [
          "rev-parse",
          "--verify",
          "--quiet",
          "refs/heads/#{worktree.branch}"
        ])
      )

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
