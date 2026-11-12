defmodule WardrikCore.CredentialsTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Authorization
  alias WardrikCore.Context
  alias WardrikCore.Credentials
  alias WardrikCore.Principal
  alias WardrikCore.Resume
  alias WardrikCore.Turn

  defmodule Vault do
    @behaviour WardrikCore.Credentials

    @impl true
    def resolve(%{name: "broken"}, _granted), do: {:error, "The vault is sealed."}

    def resolve(%{name: name, principal: %Principal{id: id}}, granted) do
      case :ets.lookup(granted, {name, id}) do
        [{_key, token}] -> {:ok, token}
        [] -> {:authorize, "https://example.com/sign-in/#{name}"}
      end
    end

    @impl true
    def refused(%{name: name, principal: %Principal{id: id}}, granted) do
      :ets.delete(granted, {name, id})
      :ok
    end
  end

  defmodule Forgetful do
    @behaviour WardrikCore.Credentials

    @impl true
    def resolve(_request, _opts), do: {:ok, "the-only-token"}
  end

  defmodule Issues do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, _opts) do
      [
        WardrikCore.Tool.new!(
          name: "create_issue",
          description: "Opens an issue.",
          run: fn _args, context ->
            with {:ok, token} <- Credentials.fetch(context, "github"),
                 do: {:ok, "opened with #{token}"}
          end
        )
      ]
    end
  end

  setup do
    granted = :ets.new(:granted, [:public])
    maria = %Principal{id: "user:maria"}

    context =
      Context.new(
        model: "anthropic:claude-haiku-4-5",
        credentials: {Vault, granted},
        capabilities: [Issues],
        messages: [ReqLLM.Context.user("Open an issue.", %{principal: maria})]
      )

    %{context: context, granted: granted, maria: maria}
  end

  test "fetches a credential for whoever the turn acts for", %{context: context, granted: granted} do
    :ets.insert(granted, {{"github", "user:maria"}, "maria-token"})

    assert {:ok, "maria-token"} = Credentials.fetch(context, "github")
  end

  test "parks on a sign-in the person hasn't finished", %{context: context, maria: maria} do
    assert {:park,
            %Authorization{
              url: "https://example.com/sign-in/github",
              credential: "github",
              principal: ^maria
            }} = Credentials.fetch(context, "github")
  end

  test "passes on what the credentials can't give", %{context: context} do
    assert {:error, "The vault is sealed."} = Credentials.fetch(context, "broken")
    assert {:error, _reason} = Credentials.fetch(%{context | credentials: nil}, "github")
  end

  test "a refused credential isn't given again", %{context: context, granted: granted} do
    :ets.insert(granted, {{"github", "user:maria"}, "revoked-token"})

    assert :ok = Credentials.refused(context, "github")
    assert {:park, %Authorization{}} = Credentials.fetch(context, "github")
  end

  test "credentials that can't be told of a refusal are left as they are", %{context: context} do
    assert :ok = Credentials.refused(%{context | credentials: Forgetful}, "github")
    assert :ok = Credentials.refused(%{context | credentials: nil}, "github")
  end

  test "a call parked on a sign-in runs again once the person has signed in",
       %{context: context, granted: granted} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "create_issue")])} end)

    assert {:park, {:tool_calls, [{_call, {:park, %Authorization{}}}]} = reason, parked} =
             Turn.run(context)

    :ets.insert(granted, {{"github", "user:maria"}, "maria-token"})

    expect(ReqLLM, :stream_text, fn _, messages, _ ->
      assert %{role: :tool, content: [%{text: "opened with maria-token"}]} = List.last(messages)
      {:ok, answer("Done.")}
    end)

    assert {:ok, _context} = Turn.resume(parked, %Resume{reason: reason, input: %{}})
  end
end
