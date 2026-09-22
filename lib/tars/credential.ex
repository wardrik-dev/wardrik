defmodule Tars.Credential do
  @moduledoc """
  A secret a tool needs, named rather than held.

  Tars stores no credentials. A tool declares what it needs as a reference and
  asks the scope to resolve it when it calls:

      case Tars.Credential.resolve(scope, {:user, "github"}) do
        {:ok, credential} -> Req.get(url, auth: {:bearer, Tars.Credential.reveal(credential)})
        {:error, {:authorization_required, url}} -> {:park, "Connect GitHub: " <> url}
        {:error, reason} -> Tars.Tool.Result.error(reason)
      end

  A deployment names a `Tars.Credential` module on the scope, the way it names
  a policy, and that module decides where secrets come from. A run with no
  resolver resolves nothing, so the default costs nothing.

  ## References

    * `{:user, name}` - the acting user's credential for `name`, whoever
      `scope.user` says that is
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
  could have this credential but has not connected yet. A tool answering with
  `{:park, prompt}` stops the turn until they do; see `c:Tars.Tool.tool/0`.

  A resolver that sends the user somewhere else to authorize keeps
  `continuation/0` alongside whatever it started, and applies it when the
  credential becomes resolvable. The parked call is answered where the user
  finished, rather than waiting to be told a second time.
  """

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
          | {:error, term()}

  @typedoc "How to answer the call that a credential is being resolved for."
  @type continuation() :: mfa()

  @doc """
  Resolves one reference for the principal a scope names.

  Called in the process making the call, as often as the call is made. A
  resolver that caches is free to; core asks every time.
  """
  @callback resolve(ref(), Scope.t()) :: outcome()

  @doc """
  Approves the call this credential is being resolved for, as an MFA to apply
  later, or `nil` when nothing is waiting on one.

  Read by a resolver in `c:resolve/2` and applied once the credential can be
  resolved. Applying it is a no-op on a turn that has already been answered.
  """
  @spec continuation() :: continuation() | nil
  def continuation do
    with %Scope{source: %{agent_id: agent_id}} <- Scope.Context.current(),
         %{id: call_id} <- Scope.Context.current_call() do
      {Tars.Agent, :decide, [agent_id, %{call_id => :approve}]}
    else
      _outside_a_call -> nil
    end
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
  Asks this scope's resolver for `ref`.

  Answers `{:error, :no_resolver}` where a deployment configured none, and
  `{:error, {:resolver_failed, reason}}` where one raised: a resolver that
  breaks must not take the turn with it.
  """
  @spec resolve(Scope.t(), ref()) :: outcome()
  def resolve(%Scope{credentials: nil}, _ref), do: {:error, :no_resolver}

  def resolve(%Scope{credentials: resolver} = scope, ref) when is_atom(resolver) do
    resolver.resolve(ref, scope)
  catch
    kind, reason -> {:error, {:resolver_failed, Exception.format(kind, reason)}}
  end

  defimpl Inspect do
    def inspect(%Tars.Credential{kind: kind}, _opts) do
      Inspect.Algebra.concat(["#Tars.Credential<", to_string(kind), ", redacted>"])
    end
  end
end
