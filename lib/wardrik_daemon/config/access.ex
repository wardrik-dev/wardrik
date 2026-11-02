defmodule WardrikDaemon.Config.Access do
  @kinds ~w(agent ceiling connection deployment mcp_server notify_target provider secret token)

  @rule [
    verbs: [
      type: {:list, :string},
      required: true,
      doc: "The actions' verbs, after the dot: `ask` for `agent.ask`, or `\"*\"` for every verb."
    ],
    kinds: [
      type: {:list, {:in, @kinds ++ ["*"]}},
      required: true,
      doc:
        "The resources' kinds: #{Enum.map_join(@kinds, ", ", &"`#{&1}`")}, or `\"*\"` for " <>
          "every kind."
    ],
    names: [
      type: {:list, :string},
      doc: "The resources' IDs, exactly, as `payments/triage`. Every ID unless set."
    ]
  ]

  @role [rules: [type: {:list, {:map, :string, :any}}, required: true]]

  @binding [
    org: [
      type: :string,
      required: true,
      doc: "The org it holds in, or `\"*\"` for every org and the deployment."
    ],
    role: [type: :string, required: true, doc: "One of `roles`."],
    subjects: [
      type: {:list, {:custom, __MODULE__, :subject, []}},
      required: true,
      doc: "Who it gives the role to: `user:ID`, `group:NAME` or `agent:ID`."
    ]
  ]

  @moduledoc """
  Reads `config.yaml`'s `roles` and `bindings`: who may do what, as Kubernetes RBAC says it.

      roles:
        reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
        operator: {rules: [{verbs: ["*"], kinds: ["*"]}]}
      bindings:
        - {org: payments, role: operator, subjects: [user:ana, group:payments-eng]}
        - {org: payments, role: reader, subjects: [agent:payments/triage]}

  A role is a list of `rules`. A rule allows an action when its verb, its resource's kind and,
  if `names` is set, its resource's ID all match:

  #{NimbleOptions.docs(NimbleOptions.new!(@rule))}

  A binding gives one role to its subjects within one org:

  #{NimbleOptions.docs(NimbleOptions.new!(@binding))}

  `admin` is every verb on every kind, `token` too, and `roles` can't declare it. The
  deployment's admin, `user:admin`, which the `wardrik` command acts as, is always bound to it in
  `"*"`, so no config.yaml narrows it. `operator` is the same, unless `roles` declares it. Only the
  admin's binding should need `"*"`: the deployment itself is in no org, nor are its secrets or
  tokens. A token acts as its subject, so whoever may create tokens may act as the people they name;
  give `token` sparingly, with `names` to say which subjects. Only the admin makes one for
  `user:admin`.

  See `WardrikDaemon.Authorizer` for how they decide.
  """

  alias WardrikDaemon.Config.Options

  @admin "admin"
  @everything %{verbs: ["*"], kinds: ["*"], names: nil}

  @type rule() :: %{verbs: [String.t()], kinds: [String.t()], names: [String.t()] | nil}
  @type binding() :: %{org: String.t(), role: String.t(), subjects: [String.t()]}
  @type t() :: %{roles: %{String.t() => [rule()]}, bindings: [binding()]}

  @doc "Returns the deployment's admin, as a principal ID."
  @spec admin() :: String.t()
  def admin, do: @admin

  @doc """
  Returns the roles and bindings `roles` and `bindings` declare, with the admin's.

  `orgs` are the orgs `config.yaml` declares, which bindings may name.
  """
  @spec read(term(), term(), [String.t()]) :: {:ok, t()} | {:error, String.t()}
  def read(roles, bindings, orgs) do
    with {:ok, roles} <- roles(roles),
         :ok <- reserved(roles),
         roles = roles |> Map.put_new("operator", [@everything]) |> Map.put(@admin, [@everything]),
         {:ok, bindings} <- bindings(bindings, roles, orgs) do
      admin = %{org: "*", role: @admin, subjects: ["user:" <> @admin]}
      {:ok, %{roles: roles, bindings: [admin | bindings]}}
    end
  end

  @doc false
  def subject("user:" <> id = subject) when id != "", do: {:ok, subject}
  def subject("group:" <> name = subject) when name != "", do: {:ok, subject}
  def subject("agent:" <> id = subject) when id != "", do: {:ok, subject}
  def subject(other), do: {:error, "#{inspect(other)} isn't user:ID, group:NAME or agent:ID"}

  defp reserved(roles) do
    if Map.has_key?(roles, @admin),
      do:
        {:error, "roles.#{@admin}: is the deployment admin's own role, so it can't be declared"},
      else: :ok
  end

  defp roles(roles) do
    with {:ok, roles} <- Options.each(roles, &role/2), do: {:ok, Map.new(roles)}
  end

  defp role(name, role) do
    path = "roles.#{name}"

    with {:ok, opts} <- Options.validate(role, @role, path),
         do: indexed(opts[:rules], "#{path}.rules", &rule/2)
  end

  defp rule(rule, path) do
    with {:ok, opts} <- Options.validate(rule, @rule, path),
         do: {:ok, %{verbs: opts[:verbs], kinds: opts[:kinds], names: opts[:names]}}
  end

  defp bindings(bindings, roles, orgs),
    do: indexed(bindings, "bindings", &binding(&1, &2, {roles, orgs}))

  defp binding(binding, path, {roles, orgs}) do
    with {:ok, opts} <- Options.validate(binding, @binding, path) do
      cond do
        not Map.has_key?(roles, opts[:role]) ->
          {:error, "#{path}.role: names #{opts[:role]}, which roles doesn't declare"}

        opts[:org] != "*" and opts[:org] not in orgs ->
          {:error, "#{path}.org: names #{opts[:org]}, which config.yaml doesn't declare"}

        true ->
          {:ok, %{org: opts[:org], role: opts[:role], subjects: opts[:subjects]}}
      end
    end
  end

  defp indexed(items, path, read) do
    with {:ok, read} <-
           items
           |> Enum.with_index()
           |> Options.each(fn item, index -> read.(item, "#{path}.#{index}") end),
         do: {:ok, Enum.map(read, &elem(&1, 1))}
  end
end
