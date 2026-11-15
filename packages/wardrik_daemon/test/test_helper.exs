# reach.check runs earlier in the same VM during precommit, and sets the logger back to debug.
Logger.configure(level: :warning)

# Wardrik.Testing.Model is called as vllm:test, which ReqLLM's catalog doesn't list.
Application.put_env(:req_llm, :warn_unverified_models, false)

Mimic.copy(ReqLLM)
Mimic.copy(ReqLLM.StreamResponse)
Mimic.copy(Wardrik.MCP)
Mimic.copy(Wardrik.Egress)
Mimic.copy(Wardrik.OAuth.Browser)
Mimic.copy(Wardrik.OAuth.Device)

WardrikDaemon.Test.start_store()
ExUnit.start(exclude: [:corpus], assert_receive_timeout: 1_000)
