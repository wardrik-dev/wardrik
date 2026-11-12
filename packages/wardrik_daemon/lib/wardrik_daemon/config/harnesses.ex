defmodule WardrikDaemon.Config.Harnesses do
  @moduledoc """
  Reads `config.yaml`'s `harnesses` and `checkouts`: the coding agents agents may call, and the
  git repositories they work in.

      harnesses:
        claude:
          command: claude-agent-acp
          env: {ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"}
          meta: {claudeCode: {options: {settingSources: []}}}
          options: {mode: default}
          context: [CLAUDE.md, AGENTS.md]
          timeout: 1800
      checkouts:
        billing: ~/src/billing
        core: {path: ~/src/core, base: origin/main, fetch: true}

    * Each harness is a tool of the same name: an agent file lists `tools: [claude]`.
    * A harness takes `WardrikACP.Harness`'s options. `timeout` and `idle` are in seconds.
    * A checkout is a git repository with a commit: its path, or `WardrikACP.Checkout`'s options.
      New work starts from `base`. Worktrees go in the data directory's `worktrees`.
    * A daily sweep removes each worktree whose work is in its checkout's `base`. See
      `WardrikACP.sweep/1`.
    * A harness no entry in `orgs` lists is the deployment's org's.
  """

  alias WardrikDaemon.Config.Options

  @seconds [:timeout, :idle]

  @doc "Returns the harnesses `section` names, as `WardrikACP` takes them, or the key that doesn't read."
  @spec read(map()) :: {:ok, keyword()} | {:error, String.t()}
  def read(section) do
    Options.loaded([WardrikACP.Harness])
    Options.each(section, &harness/2)
  end

  @doc "Returns the checkouts `section` names, each as `WardrikACP.Checkout`'s options."
  @spec checkouts(map()) :: {:ok, keyword()} | {:error, String.t()}
  def checkouts(section) do
    Options.loaded([WardrikACP.Checkout])
    Options.each(section, &checkout/2)
  end

  defp harness(name, harness) when is_map(harness) do
    path = "harnesses.#{name}"

    with {:ok, opts} <- Options.convert(harness, [], path),
         opts = Enum.map(opts, &option/1),
         {:ok, _harness} <- Options.built(fn -> WardrikACP.Harness.new!(name, opts) end, path) do
      {:ok, opts}
    end
  end

  defp harness(name, _harness),
    do: {:error, "harnesses.#{name}: is a harness's keys, with a command"}

  defp option({key, seconds}) when key in @seconds and is_number(seconds),
    do: {key, round(seconds * 1000)}

  defp option(option), do: option

  defp checkout(name, path) when is_binary(path), do: checkout(name, %{"path" => path})

  defp checkout(name, checkout) when is_map(checkout) do
    path = "checkouts.#{name}"

    with {:ok, opts} <- Options.convert(checkout, [], path),
         {:ok, built} <- Options.built(fn -> WardrikACP.Checkout.new!(name, opts) end, path),
         do: {:ok, [path: built.path, base: built.base, fetch: built.fetch]}
  end

  defp checkout(name, _checkout),
    do: {:error, "checkouts.#{name}: is a repository's path, or its path, base and fetch"}
end
