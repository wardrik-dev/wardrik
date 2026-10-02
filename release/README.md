# The release

`wardrikd`: the [daemon](../packages/wardrik_daemon) and every package, with
its own ERTS, as one directory and a tarball. `bin/wardrik` is the command a
person runs and `bin/wardrikd` the node's own script.

```sh
MIX_ENV=prod mix release
_build/prod/rel/wardrikd/bin/wardrik init
```

`config/` is what the release boots with: `config.exs` and `prod.exs` when it
is built, and `runtime.exs` each time it starts, which reads `config.yaml`'s
storage and cluster and starts the daemon beside core. `rel/` is the script
that gives each install a cookie of its own and keeps distribution on
loopback, and the `wardrik` command.

The `Dockerfile` at the root of the repository builds the image and the
tarball the install script installs, on Ubuntu 22.04, so the tarball runs on
any Linux with glibc 2.35 and OpenSSL 3.
