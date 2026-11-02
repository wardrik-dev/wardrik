defmodule Wardrik.Resolver do
  @moduledoc """
  Says what each agent gets: who it acts for, the policies and middleware it's held to, its
  defaults, and the servers and notify targets its definition's names reach. See
  `Wardrik.Resolved`.

      Wardrik.start_link(name: MyApp.AgentRuntime, resolver: {MyApp.Agents, []})

      defmodule MyApp.Agents do
        @behaviour Wardrik.Resolver

        @impl true
        def resolve(%Wardrik.Resolver.Request{agent: id}, _opts) do
          agent = MyApp.Agents.get!(id)

          {:ok,
           %Wardrik.Resolved{
             principal: %WardrikCore.Principal{id: agent.owner_id},
             policy: MyApp.Billing.policy(agent.org),
             servers: Map.new(agent.org.servers, &{&1.name, &1.key})
           }}
        end
      end

  Wardrik resolves an agent each time it's defined, starts or wakes, at the start of each turn
  for its servers, and as each of its notices is sent. To apply new policies or defaults to
  awake agents, call `Wardrik.refresh/2`. An error keeps the agent from starting or being
  defined, with the reason:

      {:error, Wardrik.Error.new(:not_found, "There's no agent acme/scout here.")}

  Without `:resolver`, Wardrik resolves agents along the owner chain. See
  `Wardrik.Owners.Resolver`.
  """

  alias Wardrik.Error
  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal

  @doc "Returns what the request's agent gets. See `Wardrik.Resolver.Request`."
  @callback resolve(Request.t(), opts :: term()) :: {:ok, Resolved.t()} | {:error, term()}

  @doc """
  Returns what the request's agent gets, with each policy built, or an error if it doesn't
  resolve.
  """
  @spec resolve(Wardrik.t(), Request.t()) :: {:ok, Resolved.t()} | {:error, Error.t()}
  def resolve(%Wardrik{resolver: nil} = wardrik, %Request{agent: id} = request),
    do: wardrik |> Wardrik.Owners.Resolver.resolve(request) |> read(wardrik, id)

  def resolve(%Wardrik{resolver: {module, opts}} = wardrik, %Request{agent: id} = request),
    do: request |> module.resolve(opts) |> read(wardrik, id)

  @doc "Returns what the agent `id` gets, as it's defined now, or as defined by nothing."
  @spec defined(Wardrik.t(), String.t()) :: {:ok, Resolved.t()} | {:error, Error.t()}
  def defined(wardrik, id) do
    case Wardrik.Operations.Running.definition(wardrik, id) do
      {:ok, definition} -> resolve(wardrik, %Request{agent: id, definition: definition})
      {:error, _none} -> resolve(wardrik, %Request{agent: id})
    end
  end

  defp read({:ok, %Resolved{} = resolved}, wardrik, id) do
    unread = &unread(id, &1)

    with :ok <- principal(resolved.principal, unread),
         {:ok, policy} <- policy("policy", resolved.policy, unread),
         {:ok, policies} <- policies(wardrik, resolved.policies, unread),
         {:ok, servers} <- named("servers", resolved.servers, unread),
         {:ok, notify} <- named("notify", resolved.notify, unread) do
      {:ok,
       %{
         resolved
         | policy: policy,
           policies: policies,
           defaults: Wardrik.Type.json(resolved.defaults),
           middleware: List.wrap(resolved.middleware),
           servers: servers,
           notify: notify
       }}
    end
  end

  defp read({:error, %Error{} = error}, _wardrik, _id), do: {:error, error}

  defp read({:error, reason}, _wardrik, id),
    do: {:error, Error.new(:unavailable, "#{id} didn't resolve: #{inspect(reason)}")}

  defp principal(nil, _unread), do: :ok
  defp principal(%Principal{}, _unread), do: :ok
  defp principal(other, unread), do: {:error, unread.("its principal is #{inspect(other)}")}

  defp named(what, names, unread) when is_map(names) do
    if Enum.all?(names, fn {name, key} -> is_binary(name) and is_binary(key) end),
      do: {:ok, names},
      else: {:error, unread.("its #{what} map names to names")}
  end

  defp named(what, _names, unread), do: {:error, unread.("its #{what} map names to names")}

  @doc false
  @spec policies(Wardrik.t(), map(), (String.t() -> Error.t())) ::
          {:ok, %{String.t() => WardrikPolicy.t()}} | {:error, Error.t()}
  def policies(wardrik, policies, unread) do
    named = Map.new(policies, fn {name, rules} -> {to_string(name), rules} end)

    case Enum.find(Map.keys(named), &Map.has_key?(wardrik.policies, &1)) do
      nil -> each(named, &policy("policy #{&1}", &2, unread))
      name -> {:error, unread.("its policy #{name} has the name of one of the deployment's")}
    end
  end

  @doc false
  @spec each(map(), (String.t(), term() -> {:ok, term()} | {:error, Error.t()})) ::
          {:ok, map()} | {:error, Error.t()}
  def each(named, read) do
    read = Map.new(named, fn {name, value} -> {name, read.(name, value)} end)

    case Enum.find(read, &match?({_name, {:error, _error}}, &1)) do
      nil -> {:ok, Map.new(read, fn {name, {:ok, value}} -> {name, value} end)}
      {_name, error} -> error
    end
  end

  @doc false
  @spec policy(String.t(), term(), (String.t() -> Error.t())) ::
          {:ok, WardrikPolicy.t() | [WardrikPolicy.t()] | nil} | {:error, Error.t()}
  def policy(_what, nil, _unread), do: {:ok, nil}

  def policy(what, [first | _rest] = policies, unread) when not is_tuple(first) do
    read =
      policies
      |> Enum.with_index(1)
      |> Enum.map(fn {policy, n} -> policy("#{what} #{n}", policy, unread) end)

    case Enum.find(read, &match?({:error, _error}, &1)) do
      nil -> {:ok, Enum.map(read, fn {:ok, policy} -> policy end)}
      error -> error
    end
  end

  def policy(_what, %WardrikPolicy{} = policy, _unread), do: {:ok, policy}

  def policy(what, rules, unread) when is_map(rules) do
    case WardrikPolicy.decode(rules) do
      {:ok, policy} -> {:ok, policy}
      {:error, why} -> {:error, unread.("its #{what}: #{why}")}
    end
  end

  def policy(what, rules, unread) do
    {:ok, WardrikPolicy.new!(rules)}
  rescue
    error in ArgumentError -> {:error, unread.("its #{what}: #{Exception.message(error)}")}
  end

  defp unread(id, why), do: Error.new(:invalid_request, "#{id} doesn't resolve: #{why}.")
end
