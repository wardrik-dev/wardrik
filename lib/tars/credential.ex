defmodule Tars.Credential do
  @moduledoc """
  A secret a tool needs, named rather than held.

  Tars stores no credentials. A tool declares what it needs as a reference and
  asks for it to be resolved for the `Tars.Call` it was handed:

      case Tars.Credential.resolve(call, {:user, "github"}) do
        {:ok, credential} -> Tars.Call.answer(call, fetch(url, credential))
        {:error, {:authorization_required, url}} -> Tars.Call.park(call, "Connect GitHub: " <> url)
        {:error, {:authorization_required, url, code}} -> Tars.Call.park(call, "Enter " <> code <> " at " <> url)
        {:error, reason} -> Tars.Call.answer(call, Tars.Tool.Result.error(reason))
      end

  A deployment names a `Tars.Credential` module on the scope, the way it names
  a policy, and that module decides where secrets come from. A run with no
  resolver resolves nothing, so the default costs nothing.

  ## References

    * `{:user, name}` - the acting user's credential for `name`, whoever the
      call's `scope.user` says that is
    * `{:org, name}` - the organisation's own, shared by everyone in it
    * `{:named, name}` - one the deployment configured, belonging to nobody

  What a name means is the resolver's business. Core carries the reference and
  never interprets it.

  ## Secrets and placeholders

  A `:secret` holds the real value, for a tool that sets its own header in this
  process. A `:placeholder` holds a sentinel that only an egress proxy can
  exchange for the real value, for anything running where a secret must not
  reach — a sandbox, a subprocess, another machine.

  Either way the value is opaque: `inspect/1` prints `#Tars.Credential<...>`,
  and a credential belongs in neither an event, a tool result, nor durable
  state. `Tars.Tool.Result` says the same thing about what a tool hands back.

  ## How long it lasts

  A resolver that knows when its answer stops being good says so with
  `:expires_at`, in unix seconds. Anything holding a credential open — a
  connection built around it, a session it authenticates — reads
  `remaining_ms/1` to know when to stop and ask again. A credential with no
  expiry is good until something says otherwise.

  ## Asking for authorization

  `{:error, {:authorization_required, url}}` is a resolver saying the user
  could have this credential but has not connected yet, and connects at
  `url`. `{:error, {:authorization_required, url, code}}` says the same of a
  user who connects by entering `code` at `url`, on whatever device they have
  to hand. A tool that parks its call with `Tars.Call.park/2` stops the turn
  until they do; see `Tars.Tool`.

  A resolver that sends the user somewhere else to authorize keeps
  `continuation/1` alongside whatever it started, and applies it when the
  credential becomes resolvable. The parked call is answered where the user
  finished, rather than waiting to be told a second time.

  ## When a credential is refused

  A tool whose server refuses the credential it was given, with a 401 or a
  403, says so with `refused/2` before it resolves again. A resolver that
  implements `c:refused/2` stops handing out what it handed out last for
  that reference, so the next resolve renews it, or asks the user again.
  """

  alias Tars.Call
  alias Tars.Scope

  @enforce_keys [:kind, :value]
  defstruct [:kind, :value, :expires_at]

  @typedoc "Whether the value is the secret itself or a sentinel standing in for it."
  @type kind() :: :secret | :placeholder

  @typedoc "A credential, opaque to everything but the code that uses it."
  @type t() :: %__MODULE__{kind: kind(), value: binary(), expires_at: integer() | nil}

  @typedoc "What a tool asks for."
  @type ref() :: {:user, String.t()} | {:org, String.t()} | {:named, String.t()}

  @typedoc "What a resolver answers."
  @type outcome() ::
          {:ok, t()}
          | {:error, {:authorization_required, String.t()}}
          | {:error, {:authorization_required, String.t(), String.t()}}
          | {:error, term()}

  @typedoc "How to answer the call that a credential is being resolved for, as `{module, function, args}`."
  @type continuation() :: {module(), atom(), list()}

  @doc """
  Resolves one reference for the principal the call's scope names.

  Called in the process making the call, as often as the call is made. A
  resolver that caches is free to; core asks every time.
  """
  @callback resolve(ref(), Call.t()) :: outcome()

  @doc "Hears that the credential last resolved for `ref` was refused by the server it was for."
  @callback refused(ref(), Call.t()) :: :ok

  @optional_callbacks refused: 2

  @doc """
  Approves `call`, the call a credential is being resolved for, as an MFA to
  apply later, decided by `by`: the principal the resolver knows finished the
  authorization as.

  Kept by a resolver in `c:resolve/2` and applied once the credential can be
  resolved. Applying it is a no-op on a turn that has already been answered.
  """
  @spec continuation(Call.t(), Tars.Principal.t()) :: continuation()
  def continuation(
        %Call{id: call_id, scope: %Scope{source: %{agent_id: agent_id}}},
        %Tars.Principal{} = by
      ) do
    {Tars.Agent, :decide, [agent_id, %{call_id => :approve}, [by: by]]}
  end

  @doc """
  A credential holding the real value.

  `:expires_at` is unix seconds, for a resolver that knows.
  """
  @spec secret(binary(), keyword()) :: t()
  def secret(value, opts \\ []) when is_binary(value) do
    %__MODULE__{kind: :secret, value: value, expires_at: Keyword.get(opts, :expires_at)}
  end

  @doc "A credential holding a sentinel an egress proxy exchanges for the real value."
  @spec placeholder(binary(), keyword()) :: t()
  def placeholder(value, opts \\ []) when is_binary(value) do
    %__MODULE__{kind: :placeholder, value: value, expires_at: Keyword.get(opts, :expires_at)}
  end

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
  Asks the resolver of `call`'s scope for `ref`.

  Answers `{:error, :no_resolver}` where a deployment configured none, and
  `{:error, {:resolver_failed, reason}}` where one raised: a resolver that
  breaks must not take the turn with it.
  """
  @spec resolve(Call.t(), ref()) :: outcome()
  def resolve(%Call{scope: %Scope{credentials: nil}}, _ref), do: {:error, :no_resolver}

  def resolve(%Call{scope: %Scope{credentials: resolver}} = call, ref) when is_atom(resolver) do
    resolver.resolve(ref, call)
  catch
    kind, reason -> {:error, {:resolver_failed, Exception.format(kind, reason)}}
  end

  @doc """
  Tells the resolver of `call`'s scope that the credential it resolved for
  `ref` was refused. A resolver without `c:refused/2`, or one that raises, is
  passed over.
  """
  @spec refused(Call.t(), ref()) :: :ok
  def refused(%Call{scope: %Scope{credentials: resolver}} = call, ref)
      when is_atom(resolver) and resolver != nil do
    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :refused, 2),
      do: resolver.refused(ref, call)

    :ok
  catch
    _kind, _reason -> :ok
  end

  def refused(%Call{}, _ref), do: :ok

  defimpl Inspect do
    def inspect(%Tars.Credential{kind: kind}, _opts) do
      Inspect.Algebra.concat(["#Tars.Credential<", to_string(kind), ", redacted>"])
    end
  end
end
