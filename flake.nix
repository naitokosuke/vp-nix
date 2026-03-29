{
  description = "Unofficial personal Nix flake for Vite+ - Unified Toolchain for JavaScript";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, crane, rust-overlay }:
    let
      supportedSystems = [
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkVitePlus = system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          # Project requires nightly Rust (rust-toolchain.toml: nightly-2025-12-11)
          rustToolchain = pkgs.rust-bin.nightly."2025-12-11".minimal;
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

          version = "0.1.15-alpha.5";
          src = pkgs.fetchFromGitHub {
            owner = "voidzero-dev";
            repo = "vite-plus";
            rev = "v${version}";
            hash = "sha256-M785QpdqvQZFBIl/yTEe1j+LRqKg+IIqaeQXkXYNp74=";
          };

          # fspy build.rs downloads these binaries via curl at build time.
          # Pre-fetch them and provide a curl wrapper to satisfy the sandbox.
          oils-for-unix = pkgs.fetchurl {
            url = "https://github.com/branchseer/oils-for-unix-build/releases/download/oils-for-unix-0.37.0/oils-for-unix-0.37.0-darwin-arm64.tar.gz";
            hash = "sha256-OjX3rivoX80yOSzYFxUi9YIvIKaRJcXp2NaLL1yFcJg=";
          };

          uutils-coreutils = pkgs.fetchurl {
            url = "https://github.com/uutils/coreutils/releases/download/0.4.0/coreutils-0.4.0-aarch64-apple-darwin.tar.gz";
            hash = "sha256-oUi2YO6vQJr3pEBpA/k9DmcTpeua3K9xodcy8ePMNSI=";
          };

          # Fixed-output derivation: fetch vite-plus npm package with all dependencies.
          # Network access is allowed because outputHash pins the result.
          vitePlusNodeModules = pkgs.stdenv.mkDerivation {
            name = "vite-plus-node-modules-${version}";
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-3sPAgy3Tos0ywbYD4TbNuILbtoPUwtGYvKZ4HpheyGQ=";
            nativeBuildInputs = [ pkgs.nodejs pkgs.cacert ];
            buildCommand = ''
              export HOME=$TMPDIR
              export npm_config_cache=$TMPDIR/npm-cache
              mkdir work && cd work
              echo '{"dependencies":{"vite-plus":"${version}"}}' > package.json
              npm install --production --ignore-scripts
              mv node_modules $out
            '';
          };

          fakeCurl = pkgs.writeShellScriptBin "curl" ''
            for arg in "$@"; do url="$arg"; done
            case "$url" in
              *oils-for-unix*darwin-arm64*) cat "${oils-for-unix}" ;;
              *coreutils*aarch64-apple-darwin*) cat "${uutils-coreutils}" ;;
              *) echo "fakeCurl: unknown URL: $url" >&2; exit 1 ;;
            esac
          '';

          cargoVendorDir = craneLib.vendorCargoDeps { inherit src; };
        in
        craneLib.buildPackage {
          pname = "vite-plus";
          inherit version src cargoVendorDir;

          cargoExtraArgs = "-p vite_global_cli";
          nativeBuildInputs = [ fakeCurl ];

          # The workspace references packages/cli/binding which depends on
          # rolldown/ (not present in the source tree). Remove the member and
          # all rolldown path dependencies so cargo can resolve the workspace.
          postPatch = ''
            substituteInPlace Cargo.toml \
              --replace-fail 'members = ["bench", "crates/*", "packages/cli/binding"]' \
                             'members = ["crates/*"]'
            sed -i '/path = "\.\/rolldown\//d' Cargo.toml
          '';

          postInstall = ''
            cp -r --no-preserve=mode ${vitePlusNodeModules} $out/node_modules
          '';

          doCheck = false;

          meta = {
            description = "Unified toolchain for JavaScript";
            homepage = "https://github.com/voidzero-dev/vite-plus";
            license = pkgs.lib.licenses.mit;
            maintainers = [ ];
            mainProgram = "vp";
          };
        };
    in
    {
      packages = forAllSystems (system:
        let
          vite-plus = mkVitePlus system;
        in
        {
          inherit vite-plus;
          default = vite-plus;
        }
      );

      apps = forAllSystems (system:
        let
          vite-plus = mkVitePlus system;
          app = {
            type = "app";
            program = "${vite-plus}/bin/vp";
            meta = {
              description = "Unified toolchain for JavaScript";
              mainProgram = "vp";
            };
          };
        in
        {
          vite-plus = app;
          default = app;
        }
      );
    };
}
