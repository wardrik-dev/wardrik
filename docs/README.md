# Wardrik docs

The source of [docs.wardrik.dev](https://docs.wardrik.dev), built with Astro and Starlight.

```sh
cd docs
npm ci
npm run dev      # http://localhost:4321
npm run build    # writes dist/
```

- Requires Node 22+.
- The build generates the TypeScript SDK reference from `../sdk/typescript/src`, into
  `src/content/docs/sdk/`. That directory is ignored by git. Fix SDK pages in the SDK's doc comments.
- Pages are in `src/content/docs/`. The sidebar is in `astro.config.mjs`.
- Follow [STYLE.md](STYLE.md).
