{
  description = "Unofficial personal Nix flake for Vite+ - Unified Toolchain for JavaScript";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      mkVitePlus =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };

          # Project requires nightly Rust (rust-toolchain.toml: nightly-2025-12-11)
          rustToolchain = pkgs.rust-bin.nightly."2025-12-11".minimal;

          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };

          version = "0.1.15-alpha.7";
          src = pkgs.fetchFromGitHub {
            owner = "voidzero-dev";
            repo = "vite-plus";
            rev = "v${version}";
            hash = "sha256-MtUQSGCVan1F/5JEaWPYYAjnUpWsqSY1NISpa4PTmCw=";
          };

          # fspy build.rs downloads these binaries via curl at build time.
          # Pre-fetch them and provide a curl wrapper to satisfy the sandbox.
          #
          # Platform mapping for oils-for-unix and uutils-coreutils.
          # oils-for-unix only provides macOS binaries; on Linux the build uses
          # the system-provided oils package instead.
          platformBinaries = {
            "aarch64-darwin" = {
              oils = {
                url = "https://github.com/branchseer/oils-for-unix-build/releases/download/oils-for-unix-0.37.0/oils-for-unix-0.37.0-darwin-arm64.tar.gz";
                hash = "sha256-OjX3rivoX80yOSzYFxUi9YIvIKaRJcXp2NaLL1yFcJg=";
              };
              coreutils = {
                url = "https://github.com/uutils/coreutils/releases/download/0.4.0/coreutils-0.4.0-aarch64-apple-darwin.tar.gz";
                hash = "sha256-oUi2YO6vQJr3pEBpA/k9DmcTpeua3K9xodcy8ePMNSI=";
              };
            };
            "x86_64-darwin" = {
              oils = {
                url = "https://github.com/branchseer/oils-for-unix-build/releases/download/oils-for-unix-0.37.0/oils-for-unix-0.37.0-darwin-x86_64.tar.gz";
                hash = "sha256-qhIljRvVUwIBRK1h/awY59++P8OWXaMu5FiEAVMWkVE=";
              };
              coreutils = {
                url = "https://github.com/uutils/coreutils/releases/download/0.4.0/coreutils-0.4.0-x86_64-apple-darwin.tar.gz";
                hash = "sha256-bkvoQp7+hsmmAkeuepMCIe0RdwqXX7S2/Qn/jTm5oVw=";
              };
            };
            "aarch64-linux" = {
              oils = null; # oils-for-unix does not publish Linux binaries; use system oils
              coreutils = {
                url = "https://github.com/uutils/coreutils/releases/download/0.4.0/coreutils-0.4.0-aarch64-unknown-linux-gnu.tar.gz";
                hash = "sha256-AhoMGXe6FXnV6BMgAiFVibBrSkD7DhtiyZI6c7xy3uU=";
              };
            };
            "x86_64-linux" = {
              oils = null; # oils-for-unix does not publish Linux binaries; use system oils
              coreutils = {
                url = "https://github.com/uutils/coreutils/releases/download/0.4.0/coreutils-0.4.0-x86_64-unknown-linux-gnu.tar.gz";
                hash = "sha256-cmgJHJaMeSidiwge2ljnONEvmDrrY8vzBgmvYp+CJVQ=";
              };
            };
          };

          binaries = platformBinaries.${system};

          oils-for-unix =
            if binaries.oils != null then pkgs.fetchurl { inherit (binaries.oils) url hash; } else null;

          uutils-coreutils = pkgs.fetchurl { inherit (binaries.coreutils) url hash; };

          # Build pnpm dependencies as a separate derivation.
          # The lock file (pnpm/pnpm-lock.yaml) pins exact versions.
          vitePlusNodeModules = pkgs.stdenv.mkDerivation {
            pname = "vite-plus-pnpm-deps";
            inherit version;
            src = ./pnpm;

            nativeBuildInputs = [
              pkgs.pnpm_10
              pkgs.pnpmConfigHook
            ];

            pnpmDeps = pkgs.fetchPnpmDeps {
              pname = "vite-plus-pnpm-deps";
              inherit version;
              src = ./pnpm;
              hash = "sha256-y4boTd3o+M4aO6jX9ZBHVdCROMjVpQqPkvozMkrLstc="; # pnpmDepsHash
              fetcherVersion = 3;
            };

            dontBuild = true;

            installPhase = ''
              mkdir -p $out
              cp -r node_modules $out/
            '';
          };

          fakeCurl = pkgs.writeShellScriptBin "curl" (
            ''
              for arg in "$@"; do url="$arg"; done
              case "$url" in
            ''
            + (
              if oils-for-unix != null then
                ''
                  *oils-for-unix*) cat "${oils-for-unix}" ;;
                ''
              else
                ""
            )
            + ''
              *coreutils*) cat "${uutils-coreutils}" ;;
                *) echo "fakeCurl: unknown URL: $url" >&2; exit 1 ;;
              esac
            ''
          );

          # Use cargo vendor directly via a fixed-output derivation.
          # nixpkgs' fetchCargoVendor and importCargoLock both fail when
          # the same crate name+version appears from crates.io AND a git
          # source (brush-parser-0.3.0). cargo vendor handles this natively
          # by appending a hash suffix to disambiguate.
          cargoVendorDir = pkgs.stdenv.mkDerivation {
            name = "vite-plus-${version}-cargo-vendor";
            inherit src;
            nativeBuildInputs = [
              rustToolchain
              pkgs.git
              pkgs.cacert
            ];
            postUnpack = ''
              cp $sourceRoot/Cargo.lock $TMPDIR/original-Cargo.lock
            '';
            postPatch = ''
              substituteInPlace Cargo.toml \
                --replace-fail 'members = ["bench", "crates/*", "packages/cli/binding"]' \
                               'members = ["crates/*"]'
              sed -i '/path = "\.\/rolldown\//d' Cargo.toml
            '';
            buildPhase = ''
              export HOME=$TMPDIR
              export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
              vendorConfig=$(cargo -Z bindeps vendor $out)
              mkdir -p $out/.cargo
              echo "$vendorConfig" | sed "s|$out|@vendor@|g" > $out/.cargo/config.toml
              cp $TMPDIR/original-Cargo.lock $out/Cargo.lock
            '';
            dontInstall = true;
            dontFixup = true;
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-Q4rUrmMcBTmvwwlhrNiABW9CL7hf+Gxy9pa7Bk9WSh0="; # cargoVendorHash
          };

        in
        rustPlatform.buildRustPackage {
          pname = "vite-plus";
          inherit version src;
          cargoDeps = cargoVendorDir;

          cargoBuildFlags = [
            "-p"
            "vite_global_cli"
          ];
          nativeBuildInputs = [ fakeCurl ];

          # The workspace references packages/cli/binding which depends on
          # rolldown/ (not present in the source tree). Remove the member and
          # all rolldown path dependencies so cargo can resolve the workspace.
          postPatch = ''
            substituteInPlace Cargo.toml \
              --replace-fail 'members = ["bench", "crates/*", "packages/cli/binding"]' \
                             'members = ["crates/*"]'
            sed -i '/path = "\.\/rolldown\//d' Cargo.toml
            substituteInPlace crates/vite_global_cli/Cargo.toml \
              --replace-fail 'version = "0.0.0"' 'version = "${version}"'
          '';

          postInstall = ''
            cp -r --no-preserve=mode ${vitePlusNodeModules}/node_modules $out/
          '';

          doCheck = false;

          meta = {
            description = "Unified toolchain for JavaScript";
            homepage = "https://github.com/voidzero-dev/vite-plus";
            license = pkgs.lib.licenses.mit;
            maintainers = [ { github = "naitokosuke"; } ];
            mainProgram = "vp";
          };
        };
    in
    let
      systemOutputs = forAllSystems (
        system:
        let
          vp = mkVitePlus system;
          app = {
            type = "app";
            program = "${vp}/bin/vp";
            meta = {
              description = "Unified toolchain for JavaScript";
              mainProgram = "vp";
            };
          };
        in
        {
          packages = {
            vite-plus = vp;
            default = vp;
          };
          apps = {
            vite-plus = app;
            default = app;
          };
        }
      );
    in
    {
      packages = nixpkgs.lib.mapAttrs (_: v: v.packages) systemOutputs;
      apps = nixpkgs.lib.mapAttrs (_: v: v.apps) systemOutputs;
      formatter = forAllSystems (system: (import nixpkgs { inherit system; }).nixfmt);

      overlays.default = final: prev: {
        vite-plus = self.packages.${final.system}.vite-plus;
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nodejs
              pkgs.nix-prefetch
              pkgs.prefetch-npm-deps
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          vite-plus = mkVitePlus system;
        in
        {
          vite-plus-version = nixpkgs.legacyPackages.${system}.runCommand "vite-plus-version-check" {} ''
            ${vite-plus}/bin/vp --version
            touch $out
          '';
        }
      );
    };
}
