# vp-nix

Unofficial Nix flake for [vite-plus (vp)](https://github.com/voidzero-dev/vite-plus) -- Unified Toolchain for JavaScript.

The flake defines `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, and `x86_64-linux`. CI verifies builds on `aarch64-darwin` and `x86_64-linux`; the other two are not built in CI because no standard GitHub-hosted runners exist for them.

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
2. Syncs the pinned Rust nightly toolchain with the upstream `rust-toolchain.toml`
3. Updates `pnpm/package.json` and `pnpm/pnpm-lock.yaml`
4. Recomputes `pnpmDepsHash` and `cargoVendorHash`
5. Updates `CHANGELOG.md`
6. Verifies the build passes and opens a pull request automatically

## Why the pnpm and vendoring files live in this repository

Nix builds run inside a sandbox with no network access, so all dependencies must be fetched as fixed-output derivations before the build.

- **JavaScript deps:** `fetchPnpmDeps` needs a lock file to produce a reproducible `node_modules` (`pnpmDepsHash`). Because upstream does not ship a lock file suitable for this purpose, this flake maintains its own `pnpm/package.json` / `pnpm/pnpm-lock.yaml` pinning the vite-plus package.
- **Rust deps:** crates are vendored with `cargo vendor` into a fixed-output derivation (`cargoVendorHash`); this handles a crate that appears from both crates.io and a git source, which the nixpkgs `fetchCargoVendor`/`importCargoLock` helpers cannot.

The automated update workflow keeps all of these in sync whenever a new version is released.

## License

MIT
