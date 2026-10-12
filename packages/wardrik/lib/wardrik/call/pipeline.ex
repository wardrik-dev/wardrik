defmodule Wardrik.Call.Pipeline do
  @moduledoc """
  The steps every `Wardrik.Call` passes through, a tool call and a model call
  alike, the way a `Plug.Conn` passes through a pipeline.

    1. **Decide.** An unchecked call has what its tool declares written on it
       (see `Wardrik.Tool.declared/2`), and the scope's `Wardrik.Hook`s allow
       it, refuse it, or ask a person about it. `answer/2` writes on a call
       that waited what a person decided.
    2. **Before.** A tool call that may go ahead is claimed in the scope's
       `Wardrik.Ledger`, and the credentials its tool's annotations name are
       resolved; a model call is admitted by the scope's
       `Wardrik.LLM.Dispatch`. A refused tool call is answered with why.
    3. **Invoke.** A tool call is handed to its tool with a
       `Wardrik.Tool.Context`. A model call is made by the function the caller
       hands `run/2`, which streams it where the caller's events go.
    4. **After.** A claimed tool call is settled in the ledger, one whose
       tool's answers hold labels is labelled with them, a model call is
       reported to the dispatch, every hook hears what a call it let go ahead
       did (`Wardrik.Hook.settle/1`), and what was resolved for the call is
       dropped.

  Each step acts on the calls in the states it is for and hands every other
  on as it came, so a call answered, refused or waiting on a person passes
  through the steps after it.

  ## Tool calls

  A tool call reports what happens to it on its span: `:tool_parked` when it
  waits on a person, `:tool_denied` when it is refused, `:tool_replayed` when
  the ledger answers it, and `:tool_started` and `:tool_finished` around its
  tool, naming who decided it and what served it. See `Wardrik.Event`.

  A call the ledger holds as settled is answered with what it returned then,
  without running. A tool that stops to ask before doing anything waits on
  `:tool`, and gives back its claim. A credential the person has yet to
  authorize parks the call on its link, until
  `Wardrik.Credential.available/3` says it can be resolved; one the system
  refuses, `{:refused, ref}`, is resolved again and the tool handed the call
  once more. A call whose claim the ledger cannot answer does not run.

  ## In doubt

  A tool call may already have done what it does without anyone knowing how
  it ended: the ledger holds it as begun and never settled when its turn is
  replayed after a lost node, or its tool answers `{:in_doubt, reason}`, as a
  tool worker lost or late does. Such a call keeps its claim, and runs once
  more under the same idempotency key where its tool's annotations say it
  may (`in_doubt: :rerun`), handed a context that says so. Otherwise, or
  where it is in doubt again, it waits on `:doubt` for a person: approving it
  runs it again under the same key, and refusing it tells the model it may
  have run. See `Wardrik.Tool.Annotations`.

  A person who refuses a call the ledger holds tells the model what the
  ledger holds, not that it never ran.

  ## Model calls

  `model/2` is the call a request makes. A refusal from the dispatch answers
  the call with `{:error, reason}` and the caller's function is never handed
  it. The dispatch hears every call it admitted, failed or interrupted ones
  included, and the hooks hear a call that used something.
  """

  require Logger

  alias Wardrik.Call
  alias Wardrik.Call.Model
  alias Wardrik.Call.Tool
  alias Wardrik.Credential
  alias Wardrik.Event
  alias Wardrik.Hook
  alias Wardrik.Ledger
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Dispatch
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Usage
  alias Wardrik.Scope
  alias Wardrik.Subagent
  alias Wardrik.Tool.Result

  @claim :wardrik_ledger_key
  @credentials :wardrik_credentials
  @request :wardrik_request
  @in_doubt :wardrik_in_doubt
  @made :wardrik_made
  @tools :wardrik_tools

  @typedoc "Makes a model call the steps before it let go ahead, and hands it back answered."
  @type invoke() :: (Call.t() -> Call.t())

  @typedoc """
  What a person decides about a call that waits on them: approved, with a
  note for the model where they wrote one, or refused for a reason.
  """
  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @doc """
  The call `request` makes under `scope`, holding the request until `run/2`
  has made it. Given `approved`, the model call a person approved, it goes
  ahead as that call, without the hooks being asked again.
  """
  @spec model(Request.t(), Scope.t(), Call.t() | nil) :: Call.t()
  def model(request, scope, approved \\ nil)

  def model(%Request{} = request, %Scope{} = scope, nil),
    do: request |> Call.model(scope) |> Call.put_private(@request, request)

  def model(%Request{} = request, %Scope{} = scope, %Call{state: :approved} = approved) do
    %{approved | scope: scope, target: Model.new(request)}
    |> Call.put_private(@request, request)
  end

  @doc "The request a model call makes: the one the dispatch admitted, once it has."
  @spec request(Call.t()) :: Request.t()
  def request(%Call{target: %Model{}, private: %{@request => %Request{} = request}}), do: request

  @doc """
  Carries `index`, `Wardrik.LLM.Config.tool_index/1` of the call's scope's
  config, with a tool call, so its steps look its tool up there rather than
  build the scope's tools again. A caller running many calls under one scope
  builds it once for them all; a call run without one has it built as it
  begins. `run/2` drops it as it ends.
  """
  @spec indexed(Call.t(), Config.tool_index()) :: Call.t()
  def indexed(%Call{target: %Tool{}} = call, index) when is_map(index),
    do: Call.put_private(call, @tools, index)

  @doc """
  Decides an unchecked call, and hands any other on as it came. A call that
  does not go ahead holds nothing it was given to go ahead with.
  """
  @spec decide(Call.t()) :: Call.t()
  def decide(%Call{} = call),
    do: call |> indexed() |> checked() |> Map.update!(:private, &Map.delete(&1, @tools))

  defp checked(%Call{state: :unchecked, target: %Tool{}} = call) do
    call
    |> Wardrik.Tool.declared(spec(call))
    |> Hook.check()
    |> announced()
    |> held_back()
  end

  defp checked(%Call{state: :unchecked} = call), do: call |> Hook.check() |> held_back()
  defp checked(%Call{} = call), do: call

  defp held_back(%Call{state: state} = call) when state in [:denied, :waiting],
    do: forgotten(call)

  defp held_back(call), do: call

  @doc """
  Writes on a call that waits what a person decided: approved, which each
  hook that asked hears through `Wardrik.Hook.approved/1`, with the note they
  wrote, a blank one being none, or refused for the reason they gave.
  Anything else refuses it, saying so.
  """
  @spec answer(Call.t(), decision() | term()) :: Call.t()
  def answer(%Call{state: :waiting} = call, :approve), do: approved(call, nil)

  def answer(%Call{state: :waiting} = call, {:approve, note}) when is_binary(note),
    do: approved(call, note(note))

  def answer(%Call{state: :waiting} = call, {:deny, reason}) when is_binary(reason),
    do: Call.refuse(call, reason)

  def answer(%Call{state: :waiting} = call, other),
    do: Call.refuse(call, "Undecidable answer #{inspect(other)}: #{Call.prompt(call)}")

  defp approved(call, note) do
    approved = Call.approve(call, note)
    :ok = Hook.approved(approved)
    approved
  end

  @doc "`note` with its ends trimmed, or `nil` where it says nothing."
  @spec note(String.t() | nil) :: String.t() | nil
  def note(nil), do: nil

  def note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Runs `call` through every step. A tool call is handed to its tool; a model
  call, built with `model/3`, to `invoke`, which makes it and answers it with
  how it ended (see `Wardrik.Call.answer/2`).
  """
  @spec run(Call.t(), invoke() | nil) :: Call.t()
  def run(%Call{scope: %Scope{}} = call, invoke \\ nil) do
    call
    |> indexed()
    |> checked()
    |> claim()
    |> refused()
    |> resolved()
    |> admitted()
    |> invoked(invoke)
    |> recorded()
    |> labelled()
    |> settled()
    |> forgotten()
  end

  defp credentials(%Call{private: private}), do: Map.get(private, @credentials) || %{}

  defp index(%Call{private: %{@tools => index}}), do: index
  defp index(%Call{scope: scope}), do: Config.tool_index(scope.config)

  defp indexed(%Call{target: %Tool{}} = call), do: indexed(call, index(call))
  defp indexed(call), do: call

  # The call's tool as its scope's config offers it, `nil` where it leaves it
  # out, and the spec that builds it; `nil` for a tool the config does not
  # name.
  defp indexed_tool(%Call{target: %Tool{name: name}} = call), do: Map.get(index(call), name)

  defp offered(call) do
    case indexed_tool(call) do
      nil -> nil
      {tool, _spec} -> tool
    end
  end

  defp spec(call) do
    case indexed_tool(call) do
      nil -> nil
      {_tool, spec} -> spec
    end
  end

  # A call runs again in doubt where it came back so and runs once more, or a
  # person approved running it again.
  defp in_doubt?(%Call{private: %{@in_doubt => true}}), do: true
  defp in_doubt?(%Call{state: :approved} = call), do: Call.asked_by?(call, :doubt)
  defp in_doubt?(%Call{}), do: false

  # -- before ------------------------------------------------------------------

  # A call is claimed before it runs, so a replay knows it began, and settled
  # after, so a replay knows what it returned.
  defp claim(%Call{state: state, target: %Tool{}, scope: %Scope{ledger: ledger} = scope} = call)
       when state in [:allowed, :approved] and ledger != nil do
    key = Ledger.key(scope, Call.to_map(call))

    case Ledger.claim(ledger, key, Call.to_map(call)) do
      :ok ->
        Call.put_private(call, @claim, key)

      {:settled, result} ->
        replayed(call, result)

      {:pending, _entry} ->
        if in_doubt?(call) or rerun?(call),
          do: call |> Call.put_private(@claim, key) |> Call.put_private(@in_doubt, true),
          else: call |> Call.doubt("It began before this agent was interrupted.") |> announced()

      {:error, reason} ->
        Call.refuse(
          call,
          :ledger,
          "Wardrik could not record this call before running it, so it did not run: #{inspect(reason)}"
        )
    end
  end

  defp claim(call), do: call

  defp rerun?(%Call{target: %Tool{name: name}, scope: scope} = call),
    do: Config.tool_in_doubt(scope.config, name, index(call)) == :rerun

  # A refused tool call is answered with why, as an ordinary tool result. A
  # model call refused is the caller's to report.
  defp refused(%Call{state: :denied, target: %Tool{}} = call) do
    case held(call) do
      %Call{state: :denied, denied: denied} = call ->
        emit(call, {:tool_denied, call.id, Call.name(call), denied.reason, Call.decided_by(call)})
        Call.answer(call, Result.error(:denied, denied.reason))

      answered ->
        answered
    end
  end

  defp refused(call), do: call

  # A call a person refused may be one that began before, or that ran.
  defp held(%Call{denied: %{by: :person, reason: reason}} = call) do
    case fetched(call) do
      {:ok, %Ledger.Entry{result: nil}} ->
        Call.refuse(call, not_run_again(call, reason))

      {:ok, %Ledger.Entry{result: result}} ->
        replayed(call, result)

      :error ->
        if Call.asked_by?(call, :doubt),
          do: Call.refuse(call, not_run_again(call, reason)),
          else: call
    end
  end

  defp held(call), do: call

  defp fetched(%Call{scope: %Scope{ledger: nil}}), do: :error

  defp fetched(%Call{scope: %Scope{ledger: ledger} = scope} = call),
    do: Ledger.fetch(ledger, Ledger.key(scope, Call.to_map(call)))

  defp not_run_again(call, reason) do
    "#{Call.name(call)} was not run again, and may already have done what it does. #{reason}"
  end

  # The credentials a tool's annotations name are resolved before it runs,
  # and handed to it. One the person has yet to authorize parks the call on
  # its link; one that cannot be resolved answers the call with why.
  defp resolved(%Call{state: state, target: %Tool{name: name}} = call)
       when state in [:allowed, :approved] do
    Enum.reduce_while(needed(call, name), call, fn ref, call ->
      case Credential.resolve(call, ref) do
        {:ok, credential} ->
          {:cont, put_credential(call, ref, credential)}

        {:error, {:authorization_required, link, owner}} ->
          {:halt, unauthorized(call, ref, link, owner)}

        {:error, reason} ->
          {:halt, call |> Call.answer(unresolved(name, ref, reason)) |> finished()}
      end
    end)
  end

  defp resolved(call), do: call

  defp needed(call, name) do
    case spec(call) do
      nil -> []
      spec -> Wardrik.Tool.annotations(spec, name).credentials
    end
  end

  defp unauthorized(call, ref, link, owner) do
    prompt =
      "To use #{Call.name(call)}, connect #{ref} at its link. " <>
        "This carries on once it is connected."

    call |> Call.park(prompt, link: link, credential: %{ref: ref, owner: owner}) |> announced()
  end

  defp unresolved(name, ref, :no_resolver),
    do:
      Result.error(
        :not_authorized,
        "#{name} needs #{ref}, and this deployment resolves no credentials."
      )

  defp unresolved(name, ref, reason),
    do:
      Result.error(
        :not_authorized,
        "#{name} needs #{ref}, which could not be resolved: #{inspect(reason)}"
      )

  defp put_credential(call, ref, credential),
    do: Call.put_private(call, @credentials, Map.put(credentials(call), ref, credential))

  # A model call goes where its dispatch says, with the key it supplies, and
  # names the model it goes to as it is made.
  defp admitted(%Call{state: state, target: %Model{}} = call)
       when state in [:allowed, :approved] do
    case Dispatch.admit(call.scope, request(call)) do
      {:ok, admitted} ->
        %{call | target: Model.new(admitted)} |> Call.put_private(@request, admitted)

      {:error, reason} ->
        Call.answer(call, {:error, reason})
    end
  end

  defp admitted(call), do: call

  # -- invoke ------------------------------------------------------------------

  defp invoked(%Call{state: state, target: %Tool{}} = call, nil)
       when state in [:allowed, :approved] do
    call |> handed() |> again(call) |> told()
  end

  defp invoked(%Call{state: state, target: %Model{}} = call, invoke)
       when state in [:allowed, :approved] and is_function(invoke, 1),
       do: call |> invoke.() |> Call.put_private(@made, true)

  defp invoked(call, _invoke), do: call

  # A call whose work ran a delegate is labelled with what the delegate read,
  # as one that read it itself is; see `Wardrik.Subagent`.
  defp handed(%Call{target: %Tool{name: name, arguments: args}} = call) do
    emit(
      call,
      {:tool_started, call.id, name, args, Ledger.idempotency_key(call), Call.decided_by(call)}
    )

    {handed, read} = Subagent.watching(fn -> tool(call, :may_retry) end)
    handed |> Call.put_private(@made, true) |> Call.label(read)
  end

  # A call that came back in doubt runs once more where its tool says it may.
  defp again(%Call{state: :waiting} = doubted, call) do
    if Call.asked_by?(doubted, :doubt) and not in_doubt?(call) and rerun?(call),
      do: call |> Call.put_private(@in_doubt, true) |> handed(),
      else: doubted
  end

  defp again(handed, _call), do: handed

  defp told(%Call{state: :done} = call), do: finished(call)
  defp told(call), do: announced(call)

  defp tool(%Call{target: %Tool{name: name, arguments: args}} = call, retry) do
    case offered(call) do
      nil ->
        Call.answer(call, {:error, "Unknown tool: #{name}"})

      %ReqLLM.Tool{callback: {Wardrik.Tool, :invoke, [handler]}} = tool ->
        handler(call, tool, handler, retry)

      tool ->
        answered(call, ReqLLM.Tool.execute(tool, args))
    end
  end

  # A tool built with `Wardrik.Tool.new!/1` is handed its arguments and its
  # context, and what it answers is read as `t:Wardrik.Tool.answer/0`.
  defp handler(%Call{target: target} = call, tool, handler, retry) do
    case ReqLLM.Tool.validate_input(tool, target.arguments) do
      {:ok, input} ->
        context = Wardrik.Tool.Context.new(call, credentials(call), in_doubt: in_doubt?(call))
        handler |> Wardrik.Tool.hand(input, context) |> took(call, retry)

      {:error, reason} ->
        Call.answer(call, {:error, reason})
    end
  end

  defp took({:ok, output, opts}, call, _retry) when is_list(opts) do
    call
    |> answered({:ok, output})
    |> Call.served(Keyword.get(opts, :served_by))
    |> Call.label(Keyword.get(opts, :labels, []))
    |> Call.priced(Keyword.get(opts, :cost))
  end

  defp took({:park, prompt}, call, retry), do: took({:park, prompt, []}, call, retry)

  defp took({:park, prompt, opts}, call, _retry) when is_binary(prompt) and is_list(opts),
    do: Call.park(call, prompt, link: Keyword.get(opts, :link))

  defp took({:in_doubt, reason}, call, retry), do: took({:in_doubt, reason, []}, call, retry)

  defp took({:in_doubt, reason, opts}, call, _retry) when is_binary(reason) and is_list(opts),
    do: call |> Call.doubt(reason) |> Call.served(Keyword.get(opts, :served_by))

  # A credential the system refused is resolved afresh, once its resolver
  # has heard, and the call is tried once more.
  defp took({:refused, ref}, call, :may_retry) when is_binary(ref) do
    :ok = Credential.refused(call, ref)

    case Credential.resolve(call, ref) do
      {:ok, credential} -> call |> put_credential(ref, credential) |> tool(:tried)
      {:error, reason} -> Call.answer(call, unresolved(Call.name(call), ref, reason))
    end
  end

  defp took({:refused, ref}, call, :tried) when is_binary(ref) do
    Call.answer(
      call,
      Result.error(
        :not_authorized,
        "#{ref} is no longer valid: what #{Call.name(call)} reaches refused it twice."
      )
    )
  end

  defp took(other, call, _retry), do: answered(call, other)

  # A tool that answers with neither `{:ok, _}` nor `{:error, _}` is a bug in
  # the tool, and the model is told so rather than the call crashing around it.
  defp answered(call, {:ok, _output} = result), do: Call.answer(call, result)
  defp answered(call, {:error, _reason} = result), do: Call.answer(call, result)

  defp answered(call, other),
    do: Call.answer(call, {:error, "Tool answered with #{inspect(other)}"})

  # -- after -------------------------------------------------------------------

  # A claimed call is settled with what it answered. One whose tool stopped to
  # ask before doing anything gives its claim back; one in doubt keeps it, so
  # a replay asks too.
  defp recorded(%Call{private: %{@claim => key}, scope: %Scope{ledger: ledger}} = call)
       when key != nil do
    case call.state do
      :done -> settle(call, ledger, key)
      :waiting -> if Call.asked_by?(call, :tool), do: _ = Ledger.release(ledger, key)
    end

    Call.put_private(call, @claim, nil)
  end

  defp recorded(call), do: call

  defp settle(call, ledger, key) do
    with {:error, reason} <- Ledger.settle(ledger, key, call.result) do
      Logger.warning(
        "#{Call.name(call)} ran, but what it returned was not recorded: #{inspect(reason)}"
      )
    end
  end

  # A call answered by a tool whose answers hold labels carries them, whether
  # it ran now or its answer was replayed.
  defp labelled(%Call{state: :done, denied: nil, target: %Tool{name: name}} = call) do
    case spec(call) do
      nil -> call
      spec -> Call.label(call, Wardrik.Tool.annotations(spec, name).labels)
    end
  end

  defp labelled(call), do: call

  defp settled(%Call{private: %{@made => true}, target: %Model{}} = call) do
    request = request(call)
    :ok = Dispatch.settle(call.scope, request, call.result)

    case Usage.of(request, call.result) do
      nil -> call
      usage -> call |> Call.used(usage, request.model_spec) |> tap(&Hook.settle/1)
    end
  end

  defp settled(%Call{private: %{@made => true}, state: :done} = call),
    do: tap(call, &Hook.settle/1)

  defp settled(call), do: call

  # A credential is handed to the tool for the call, and a request to the
  # provider, and neither is kept.
  defp forgotten(%Call{private: private} = call),
    do: %{call | private: Map.drop(private, [@credentials, @request, @in_doubt, @made, @tools])}

  # -- events ------------------------------------------------------------------

  defp replayed(call, result) do
    emit(call, {:tool_replayed, call.id, Call.name(call), result})
    Call.answer(call, result)
  end

  defp finished(%Call{target: %Tool{}} = call) do
    emit(call, {:tool_finished, call.id, Call.name(call), call.result, call.served_by, call.cost})
    call
  end

  defp announced(%Call{state: :waiting, target: %Tool{}} = call) do
    emit(call, {:tool_parked, call.id, Call.name(call), Call.prompt(call)})
    call
  end

  defp announced(call), do: call

  defp emit(%Call{scope: %Scope{source: source}}, payload), do: Event.emit(source, payload)
end
