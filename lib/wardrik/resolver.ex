defmodule Wardrik.Resolver do
  @moduledoc """
  Says what each agent gets: who it works for, its policy, servers and more. See `Wardrik.Resolved`.

      defmodule MyApp.Agents do
        @behaviour Wardrik.Resolver

        @impl true
        def resolve(%Wardrik.Resolver.Request{agent: id}, _opts) do
          agent = MyApp.Repo.get!(MyApp.Agent, id)

          {:ok,
           %Wardrik.Resolved{
             principal: Wardrik.principal(agent.user_id),
             policy: MyApp.Billing.policy(agent.team),
             servers: Map.new(agent.team.servers, &{&1.name, &1.key})
           }}
        end
      end

  Wardrik resolves an agent as it's defined, starts or wakes, each turn, and for each notice.
  Call `Wardrik.refresh/2` to apply changes to awake agents. An error keeps the agent from
  starting:

      {:error, Wardrik.Error.new(:not_found, "There's no agent agt_scout here.")}
  """

  alias Wardrik.Error
  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal

  @doc "Returns what the request's agent gets. See `Wardrik.Resolver.Request`."
  @callback resolve(Request.t(), opts :: term()) :: {:ok, Resolved.t()} | {:error, term()}

  @doc """
  Returns what the request's agent gets, with each policy built, or an error.
  """
  @spec resolve(Wardrik.t(), Request.t()) :: {:ok, Resolved.t()} | {:error, Error.t()}
  def resolve(%Wardrik{resolver: {module, opts}} = wardrik, %Request{agent: id} = request),
    do: request |> module.resolve(opts) |> read(wardrik, id)

  @doc "Returns what the agent `id` gets, as defined now."
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
         {:ok, channels} <- named("channels", resolved.channels, unread),
         {:ok, workspaces} <- workspaces(resolved.workspaces, unread),
         {:ok, notify} <- targets(resolved.notify, unread) do
      {:ok,
       %{
         resolved
         | policy: policy,
           policies: policies,
           defaults: Wardrik.Type.json(resolved.defaults),
           middleware: List.wrap(resolved.middleware),
           servers: servers,
           channels: channels,
           workspaces: workspaces,
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

  defp workspaces(workspaces, unread) when is_map(workspaces) do
    if Enum.all?(workspaces, fn {id, access} -> is_binary(id) and access in [:read, :write] end),
      do: {:ok, workspaces},
      else: {:error, unread.("its workspaces map agent IDs to :read or :write")}
  end

  defp workspaces(_workspaces, unread),
    do: {:error, unread.("its workspaces map agent IDs to :read or :write")}

  defp targets(notify, unread) when is_map(notify) do
    each(notify, fn name, target -> target(name, target, unread) end)
  end

  defp targets(_notify, unread), do: {:error, unread.("its notify map names to targets")}

  defp target(name, key, _unread) when is_binary(name) and is_binary(key), do: {:ok, key}

  defp target(name, target, unread) when is_binary(name) do
    case Wardrik.Notify.given(target) do
      {:ok, target} -> {:ok, target}
      {:error, why} -> {:error, unread.("its notify target #{name}: #{why}")}
    end
  end

  defp target(_name, _target, unread), do: {:error, unread.("its notify map names to targets")}

  defp policies(wardrik, policies, unread) do
    named = Map.new(policies, fn {name, rules} -> {to_string(name), rules} end)

    case Enum.find(Map.keys(named), &Map.has_key?(wardrik.policies, &1)) do
      nil -> each(named, &policy("policy #{&1}", &2, unread))
      name -> {:error, unread.("its policy #{name} has the name of one of the deployment's")}
    end
  end

  defp each(named, read) do
    read = Map.new(named, fn {name, value} -> {name, read.(name, value)} end)

    case Enum.find(read, &match?({_name, {:error, _error}}, &1)) do
      nil -> {:ok, Map.new(read, fn {name, {:ok, value}} -> {name, value} end)}
      {_name, error} -> error
    end
  end

  defp policy(_what, nil, _unread), do: {:ok, nil}

  defp policy(what, [first | _rest] = policies, unread) when not is_tuple(first) do
    read =
      policies
      |> Enum.with_index(1)
      |> Enum.map(fn {policy, n} -> policy("#{what} #{n}", policy, unread) end)

    case Enum.find(read, &match?({:error, _error}, &1)) do
      nil -> {:ok, Enum.map(read, fn {:ok, policy} -> policy end)}
      error -> error
    end
  end

  defp policy(_what, %WardrikPolicy{} = policy, _unread), do: {:ok, policy}

  defp policy(what, rules, unread) when is_map(rules) do
    case WardrikPolicy.decode(rules) do
      {:ok, policy} -> {:ok, policy}
      {:error, why} -> {:error, unread.("its #{what}: #{why}")}
    end
  end

  defp policy(what, rules, unread) do
    {:ok, WardrikPolicy.new!(rules)}
  rescue
    error in ArgumentError -> {:error, unread.("its #{what}: #{Exception.message(error)}")}
  end

  defp unread(id, why), do: Error.new(:invalid_request, "#{id} doesn't resolve: #{why}.")
end
