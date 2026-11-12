# Wardrik

Runs agents with tool policies, approval checks, spending limits, and event logs.

- [Docs](https://docs.wardrik.dev)
- [Install the daemon](packages/wardrik_daemon#readme)

## Layout

| Directory | What it holds |
| --- | --- |
| `packages/` | Wardrik itself: `wardrik`, `wardrik_core`, `wardrik_protocol` and `wardrik_daemon`. |
| `extensions/` | Packages that add to Wardrik: channels, tools, harnesses, the gateway, the web dashboard. |
| `sdk/typescript` | The TypeScript SDK, `@wardrik/sdk` on npm. |
| `docs/` | The source of [docs.wardrik.dev](https://docs.wardrik.dev). |

Each Elixir package is its own Hex package, with its own version and CHANGELOG.

## Develop

Each package takes the others from this repository. Run the gate in the package you change:

```sh
cd packages/wardrik
mix deps.get
mix precommit
```

`WARDRIK_HEX=1` takes them from Hex instead, as publishing does.

## Release

`scripts/release.sh` publishes each package whose version isn't on Hex or npm yet, then tags it
`<name>-v<version>`. A `wardrik_daemon-v*` tag builds the daemon's release.

## License

Apache 2.0.
