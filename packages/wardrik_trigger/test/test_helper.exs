# Secrets are read for the agent a trigger asks, as a daemon's vault keeps
# one for each org, and from the environment past that.
Wardrik.Test.start(
  children: [
    {WardrikTrigger,
     store: Wardrik.Test.store(),
     settings: %{
       WardrikTrigger.Feed => [req_options: [plug: {Req.Test, WardrikTrigger.Feed}, retry: false]]
     }}
  ],
  wait: [WardrikTrigger.supervisor()]
)
