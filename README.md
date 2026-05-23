# vp-nix

Unofficial Nix flake for [vite-plus (vp)](https://github.com/voidzero-dev/vite-plus) -- Unified Toolchain for JavaScript.

Currently supports `aarch64-darwin` only.

## Usage

### Run directly

```sh
nix run github:naitokosuke/vp-nix -- --version
```

### Install to profile

```sh
nix profile install github:naitokosuke/vp-nix
```

### Use as a flake input

```nix
{
  inputs.vp-nix.url = "github:naitokosuke/vp-nix";

  outputs = { self, vp-nix, ... }: {
    # vp-nix.packages.aarch64-darwin.default
  };
}
```

## How the automated update works

A GitHub Actions workflow (`update-vp.yml`) runs every 12 hours to check for new vite-plus releases. When a new version is found it:

1. Updates the version and source hash in `flake.nix`
2. Updates `package.json` and `package-lock.json` for the new npm tarball
3. Recomputes `npmDepsHash` using `prefetch-npm-deps`
4. Updates `CHANGELOG.md`
5. Verifies the build passes
6. Opens a pull request automatically

## Why package.json lives in this repository

Nix builds run inside a sandbox with no network access. The `buildNpmPackage` helper needs a `package-lock.json` to produce a fixed-output derivation of npm dependencies (`npmDepsHash`). Because the upstream vite-plus repository does not ship a lock file suitable for this purpose, this flake maintains its own `package.json` / `package-lock.json` that pins the vite-plus npm tarball. The automated update workflow keeps these files in sync whenever a new version is released.

## Troubleshooting

### `vp create <name>` fails with `ERR_PNPM_DLX_NO_BIN`

```
[ERR_PNPM_DLX_NO_BIN] No binaries found in create-web
```

`vp create <name>` expands any unrecognized shorthand to `create-<name>` and runs `pnpm dlx <expanded>` without validating the result. For example, `vp create web` expands to `create-web`, which happens to exist on npm as an unrelated empty package with no executable, so pnpm aborts with `ERR_PNPM_DLX_NO_BIN`.

Use a supported builtin or shorthand instead:

```sh
vp create --list                 # show valid builtins and shorthands
vp create vite:application out   # builtin Vite application
vp create vite out               # shorthand for create-vite
```

This is upstream vite-plus behavior; see [issue #68](https://github.com/naitokosuke/vp-nix/issues/68).

## License

MIT
