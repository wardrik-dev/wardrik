defmodule WardrikDaemon.Config.Orgs do
  @schema [
    mcp: [type: {:list, :string}, default: [], doc: "The servers its agents use."],
    harnesses: [type: {:list, :string}, default: [], doc: "The coding agents its agents use."],
    channels: [type: {:list, :string}, default: [], doc: "The channels its agents use."],
    notify: [type: {:list, :string}, default: [], doc: "The targets its agents use."],
    policy: [type: :string, doc: "The policy in `policies/` its agents are held to."]
  ]

  @moduledoc """
  Reads `config.yaml`'s `orgs`: the orgs beside the deployment's own.

      orgs:
        "*":
          mcp: [search]
          policy: base
        payments:
          mcp: [stripe, github]
          harnesses: [claude]
          channels: [payments-slack]
          notify: [audit]
          policy: payments-strict

  ## Keys

  #{NimbleOptions.docs(NimbleOptions.new!(@schema))}

    * `"*"` is every org: every org uses what it lists, and is held to its policy.
    * A server, harness, channel or target no entry lists is the deployment's org's.
    * A channel serves one org, or every org if `"*"` lists it.
  """

  alias WardrikDaemon.Config.Options

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

  @type entry() :: %{
          mcp: [String.t()],
          harnesses: [String.t()],
          channels: [String.t()],
          notify: [String.t()],
          policy: String.t() | nil
        }

  @doc """
  Returns each org's entry. `defined` holds the names `mcp`, `harnesses`, `channels` and `notify`
  define.
  """
  @spec read(map(), %{String.t() => [String.t()]}) ::
          {:ok, %{String.t() => entry()}} | {:error, String.t()}
  def read(section, defined) do
    with {:ok, entries} <- Options.each(section, &entry(&1, &2, defined)),
         do: {:ok, Map.new(entries)}
  end

  @doc """
  Returns the orgs using `:kind` `:name`: `:all` if `"*"` lists it, else those listing it, else `[org]`.

      Orgs.using(orgs, kind: :mcp, name: "github", org: "acme")
  """
  @spec using(%{String.t() => entry()}, kind: atom(), name: String.t(), org: String.t()) ::
          :all | [String.t()]
  def using(orgs, args) do
    kind = Keyword.fetch!(args, :kind)
    name = Keyword.fetch!(args, :name)
    org = Keyword.fetch!(args, :org)
    listing = for {listed, entry} <- orgs, name in Map.fetch!(entry, kind), do: listed

    cond do
      "*" in listing -> :all
      listing == [] -> [org]
      true -> Enum.sort(listing)
    end
  end

  @doc """
  Returns whether `config.yaml` gives `:kind` `:name` to `:org`. The deployment has every one.

      Orgs.serves?(config, kind: :mcp, name: "github", org: "acme")
  """
  @spec serves?(%{org: String.t(), orgs: %{String.t() => entry()}},
          kind: atom(),
          name: String.t(),
          org: String.t()
        ) :: boolean()
  def serves?(%{org: own, orgs: orgs}, args) do
    org = Keyword.fetch!(args, :org)

    case using(orgs,
           kind: Keyword.fetch!(args, :kind),
           name: Keyword.fetch!(args, :name),
           org: own
         ) do
      :all -> true
      using -> org == "deployment" or org in using
    end
  end

  defp entry(org, nil, defined), do: entry(org, %{}, defined)

  defp entry(org, entry, defined) do
    path = "orgs.#{org}"

    with :ok <- named(org, path),
         {:ok, opts} <- Options.validate(entry, @schema, path),
         :ok <- listed(opts, :mcp, defined, path),
         :ok <- listed(opts, :harnesses, defined, path),
         :ok <- listed(opts, :channels, defined, path),
         :ok <- listed(opts, :notify, defined, path) do
      {:ok,
       %{
         mcp: opts[:mcp],
         harnesses: opts[:harnesses],
         channels: opts[:channels],
         notify: opts[:notify],
         policy: opts[:policy]
       }}
    end
  end

  defp named("*", _path), do: :ok

  defp named("deployment", path),
    do: {:error, "#{path}: is the deployment's own namespace, not an org"}

  defp named(org, path) do
    if Regex.match?(@name, org),
      do: :ok,
      else: {:error, "#{path}: isn't an org's name: letters, digits, _, . and -"}
  end

  defp listed(opts, kind, defined, path) do
    known = Map.get(defined, Atom.to_string(kind), [])

    case Enum.find(opts[kind], &(&1 not in known)) do
      nil -> :ok
      unknown -> {:error, "#{path}.#{kind}: names #{unknown}, which #{kind} doesn't define"}
    end
  end
end
