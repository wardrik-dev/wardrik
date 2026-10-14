# Secrets are read for the agent a trigger asks, as a daemon's vault keeps
# one for each org, and from the environment past that.
secrets = fn
  "WARDRIK_TEST_VAULTED", %Wardrik.AgentID{org: "acme"} -> "acme's"
  "WARDRIK_TEST_VAULTED", %Wardrik.AgentID{org: "globex"} -> "globex's"
  name, _agent -> System.get_env(name)
end

Wardrik.Test.start(
  children: [{WardrikTrigger, store: Wardrik.Test.store(), secrets: secrets}],
  wait: [WardrikTrigger.supervisor()]
)
