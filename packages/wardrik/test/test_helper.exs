# reach.check runs earlier in the same VM during precommit, and sets the logger back to debug.
Logger.configure(level: :warning)

# Wardrik.Testing.Model is called as vllm:test, which ReqLLM's catalog doesn't list.
Application.put_env(:req_llm, :warn_unverified_models, false)

Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)
Mimic.copy(Wardrik.MCP)
Mimic.copy(WardrikCore)
Mimic.copy(Wardrik.Store)
Mimic.copy(Anubis.Client)

# The runtime the policy tests run their agents on.
{:ok, _} =
  Supervisor.start_link(
    [
      {WardrikCore.Backends.MemoryStore, name: :wardrik_policy_test},
      {WardrikCore,
       prefix: "test/", backend: {WardrikCore.Backends.MemoryStore, name: :wardrik_policy_test}}
    ],
    strategy: :rest_for_one
  )

Wardrik.Test.Store.start()
ExUnit.start(exclude: [:corpus], assert_receive_timeout: 1_000)
