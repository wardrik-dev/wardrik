defmodule Wardrik.Credential do
  @moduledoc """
  A secret a tool needs, named rather than held.

  Wardrik stores no credentials. A tool names what it needs in its
  annotations, and the runtime resolves each name for the call it is about
  to run and hands what it resolved to the tool in its `Wardrik.Tool.Context`:

      @impl true
      def annotations(_name), do: %{credentials: ["github"]}

      def run(%{url: url}, %Wardrik.Tool.Context{credentials: %{"github" => credential}}),
        do: fetch(url, credential)

  A deployment names its `Wardrik.Credentials` once, on its `Wardrik.Host`,
  and that decides where secrets come from. A host with none resolves
  nothing, so the default costs nothing.

  ## Names, and whose

  A credential is named, as `"github"`, and belongs to someone: the call's
  user, its org, or the deployment. Which one a name resolves to is the
  resolver's business, as is what the name means; `WardrikVault` takes the
  most specific it holds, the user's before the org's before the
  deployment's. Core carries the name and never interprets it.

  A resolved credential says whose it is as `:owner`, an opaque term, so a
  tool holding something open per credential, such as a connection, holds one
  for each owner and never lends one owner's to another.

  ## Secrets and placeholders

  A `:secret` holds the real value, for a tool that sets its own header in this
  process. A `:placeholder` holds a sentinel that only an egress proxy can
  exchange for the real value, for anything running where a secret must not
  reach — a sandbox, a subprocess, another machine.

  Either way the value is opaque: `inspect/1` prints `#Wardrik.Credential<...>`,
  and a credential belongs in neither an event, a tool result, nor durable
  state. `Wardrik.Tool.Result` says the same thing about what a tool hands back.

  ## How long it lasts

  A resolver that knows when its answer stops being good says so with
  `:expires_at`, in unix seconds. Anything holding a credential open — a
  connection built around it, a session it authenticates — reads
  `remaining_ms/1` to know when to stop and ask again. A credential with no
  expiry is good until something says otherwise.

  ## Asking for authorization

  `{:error, {:authorization_required, link, owner}}` is a resolver saying
  that `owner` could have this credential but has not connected yet, and
  connects at `link`: `%{url: url, code: code}`, with a code where they
  connect by entering it at `url`, on whatever device they have to hand, and
  `nil` where following the link is enough. The runtime parks the call on
  the link, and the call carries on by itself once the resolver says, with
  `available/3`, that the credential can now be resolved for that owner. Who
  the owner is, the resolver decides, as it decides whose a resolved
  credential is; the runtime compares what it is told and never reads it.

  A tool whose credential the system it reaches refuses answers
  `{:refused, name}`; the runtime tells the resolver through `refused/2`,
  resolves the name again and runs the tool once more.

  ## When a credential is refused

  A tool whose server refuses the credential it was given, with a 401 or a
  403, says so with `refused/2` before it resolves again. The host's
  `Wardrik.Credentials` stop handing out what it handed out last for
  that reference, so the next resolve renews it, or asks the user again.
  """

  alias Wardrik.Call
  alias Wardrik.Fleet
  alias Wardrik.Run

  defmodule Available do
    @moduledoc """
    Word that a credential can now be resolved: `ref` for `owner`, as
    `Wardrik.Credential.available/3` sends it to every agent, and `by`, the
    `Wardrik.Principal` that made it so, or `nil`.
    """

    @enforce_keys [:ref, :owner]
    defstruct [:ref, :owner, :by]

    @type t() :: %__MODULE__{
            ref: Wardrik.Credential.ref(),
            owner: Wardrik.Credential.owner(),
            by: Wardrik.Principal.t() | nil
          }
  end

  @enforce_keys [:kind, :value]
  defstruct [:kind, :value, :expires_at, :owner]

  @typedoc "Whether the value is the secret itself or a sentinel standing in for it."
  @type kind() :: :secret | :placeholder

  @typedoc "Whose a credential is: an opaque term the resolver chooses, such as a user within an org."
  @type owner() :: term()

  @typedoc "A credential, opaque to everything but the code that uses it."
  @type t() :: %__MODULE__{
          kind: kind(),
          value: binary(),
          expires_at: integer() | nil,
          owner: owner()
        }

  @typedoc "What a tool asks for: a credential's name."
  @type ref() :: String.t()

  @typedoc "What a resolver answers."
  @type outcome() ::
          {:ok, t()}
          | {:error, {:authorization_required, Call.Ask.link(), owner()}}
          | {:error, term()}

  @doc """
  Says that `ref` can now be resolved for `owner`, so a call parked on it
  carries on.

  Every agent awake in the cluster hears it, as an `Available`, and one
  holding a call parked to resolve `ref` for `owner` approves the call as
  `:by`, the `Wardrik.Principal` that connected it, and carries on with nobody
  asked. One asleep with such a call is woken to hear it. A resolver says it
  once the credential is kept where the next `Wardrik.Credentials.resolve/3`
  finds it.
  """
  @spec available(ref(), owner(), by: Wardrik.Principal.t() | nil) :: :ok
  def available(ref, owner, opts \\ []) when is_binary(ref) and is_list(opts) do
    word = %Available{ref: ref, owner: owner, by: Keyword.get(opts, :by)}

    Enum.each(Fleet.held(Wardrik.Resource.parse!("*")), fn
      %{asleep: false, pid: pid} -> send(pid, word)
      %{asleep: true, status: :parked, id: id} -> wake_awaiting(id, word)
      %{asleep: true} -> :ok
    end)
  end

  defp wake_awaiting(id, %Available{ref: ref, owner: owner} = word) do
    with {:ok, dumped} <- Fleet.written(id),
         [_ | _] <- Wardrik.Agent.State.Stored.awaiting(dumped, ref, owner),
         pid when is_pid(pid) <- Fleet.held_pid(id) do
      send(pid, word)
    end

    :ok
  end

  @doc """
  A credential holding the real value.

  `:expires_at` is unix seconds, for a resolver that knows, and `:owner`
  whose it is.
  """
  @spec secret(binary(), keyword()) :: t()
  def secret(value, opts \\ []) when is_binary(value), do: new(:secret, value, opts)

  @doc "A credential holding a sentinel an egress proxy exchanges for the real value."
  @spec placeholder(binary(), keyword()) :: t()
  def placeholder(value, opts \\ []) when is_binary(value), do: new(:placeholder, value, opts)

  defp new(kind, value, opts),
    do: %__MODULE__{
      kind: kind,
      value: value,
      expires_at: Keyword.get(opts, :expires_at),
      owner: Keyword.get(opts, :owner)
    }

  @doc """
  How long this credential is still good for, in milliseconds.

  `:infinity` where it does not expire, and zero once it has, so a caller can
  pass it to anything taking a timeout without checking for a negative.
  """
  @spec remaining_ms(t()) :: timeout()
  def remaining_ms(%__MODULE__{expires_at: nil}), do: :infinity

  def remaining_ms(%__MODULE__{expires_at: at}) do
    max((at - System.system_time(:second)) * 1000, 0)
  end

  @doc """
  The value, for the one line that puts it in a header.

  Every other use is a leak waiting to happen: do not log it, return it, or
  keep it.
  """
  @spec reveal(t()) :: binary()
  def reveal(%__MODULE__{value: value}), do: value

  @doc """
  Asks the `Wardrik.Credentials` of the host `call` runs on for
  `ref`.

  Answers `{:error, :no_resolver}` where the host holds none, and
  `{:error, {:resolver_failed, reason}}` where resolving raised: credentials
  that break must not take the turn with them.
  """
  @spec resolve(Call.t(), ref()) :: outcome()
  def resolve(%Call{run: %Run{host: host}} = call, ref) do
    Wardrik.Credentials.resolve(Wardrik.Host.credentials(host), ref, call)
  catch
    kind, reason -> {:error, {:resolver_failed, Exception.format(kind, reason)}}
  end

  @doc """
  Tells the `Wardrik.Credentials` of the host `call` runs on that the
  credential they resolved for `ref` was refused.
  """
  @spec refused(Call.t(), ref()) :: :ok
  def refused(%Call{run: %Run{host: host}} = call, ref),
    do: :ok = Wardrik.Credentials.refused(Wardrik.Host.credentials(host), ref, call)

  defimpl Inspect do
    def inspect(%Wardrik.Credential{kind: kind}, _opts) do
      Inspect.Algebra.concat(["#Wardrik.Credential<", to_string(kind), ", redacted>"])
    end
  end
end
