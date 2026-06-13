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
      inherit (nixpkgs) lib;

      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = lib.genAttrs supportedSystems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

      # rolldown/ and packages/cli/binding are absent from the published source
      # tree, so drop them before cargo resolves the workspace. Shared between
      # the cargo-vendor FOD and the build so the two patches cannot drift.
      patchWorkspace = ''
        substituteInPlace Cargo.toml \
          --replace-fail 'members = ["bench", "crates/*", "packages/cli/binding"]' \
                         'members = ["crates/*"]'
        sed -i '/path = "\.\/rolldown\//d' Cargo.toml
      '';

      mkVitePlus =
        system:
        let
          pkgs = pkgsFor system;

          # Pinned nightly from upstream rust-toolchain.toml (synced by update-vp.yml).
          rustToolchain = pkgs.rust-bin.nightly."2026-05-24".minimal;

          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };

          version = "0.1.24";
          src = pkgs.fetchFromGitHub {
            owner = "voidzero-dev";
            repo = "vite-plus";
            rev = "v${version}";
            hash = "sha256-pGbCe+Aw2fwZSw+ESZphP3Zymo/NceieTRHzhedGduE=";
          };

          # fspy's build.rs only downloads these via curl on macOS; it returns
          # early on other targets and uses seccomp on Linux, so they are null
          # there and nothing is fetched.
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
              oils = null;
              coreutils = null;
            };
            "x86_64-linux" = {
              oils = null;
              coreutils = null;
            };
          };

          binaries = platformBinaries.${system};

          oils-for-unix =
            if binaries.oils != null then pkgs.fetchurl { inherit (binaries.oils) url hash; } else null;

          uutils-coreutils =
            if binaries.coreutils != null then
              pkgs.fetchurl { inherit (binaries.coreutils) url hash; }
            else
              null;

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
              hash = "sha256-zrrk6xs7zkbh++vOPwDyRCgBuW+hSsfaTnnlUsRFRMg="; # pnpmDepsHash
              fetcherVersion = 3;
            };

            dontBuild = true;

            installPhase = ''
              mkdir -p $out
              cp -r node_modules $out/
            '';
          };

          # fspy's build.rs fetches the bundled binaries with curl, which the
          # sandbox blocks; this wrapper serves the pre-fetched files instead.
          # Only used on macOS (see nativeBuildInputs), where both are present.
          fakeCurl = pkgs.writeShellScriptBin "curl" ''
            for arg in "$@"; do url="$arg"; done
            case "$url" in
              *oils-for-unix*) cat "${oils-for-unix}" ;;
              *coreutils*) cat "${uutils-coreutils}" ;;
              *) echo "fakeCurl: unknown URL: $url" >&2; exit 1 ;;
            esac
          '';

          # fetchCargoVendor and importCargoLock both choke when the same
          # crate name+version comes from both crates.io and a git source
          # (brush-parser-0.3.0); cargo vendor disambiguates with a hash suffix.
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
            postPatch = patchWorkspace;
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
            outputHash = "sha256-e6rseTRsunne5qiE4lKJkRfhf+klsC5fXGqY3lCkB6I="; # cargoVendorHash
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

          nativeBuildInputs = lib.optionals pkgs.stdenv.isDarwin [ fakeCurl ];

          postPatch = patchWorkspace;

          postInstall = ''
            cp -r --no-preserve=mode ${vitePlusNodeModules}/node_modules $out/

            # The store pins files to 0444, but `vp create` copies templates
            # with fs.copyFileSync (mode-preserving) and then editJsonFile fails
            # with EACCES on the read-only copy. Chmod each copied file to 0644.
            substituteInPlace $out/node_modules/vite-plus/dist/create/bin.js \
              --replace-fail 'else fs.copyFileSync(src, dest);' \
                             'else { fs.copyFileSync(src, dest); fs.chmodSync(dest, 0o644); }'
          '';

          doCheck = false;

          meta = {
            description = "Unified toolchain for JavaScript";
            homepage = "https://github.com/voidzero-dev/vite-plus";
            license = lib.licenses.mit;
            maintainers = [ { github = "naitokosuke"; } ];
            mainProgram = "vp";
          };
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          vp = mkVitePlus system;
        in
        {
          vite-plus = vp;
          default = vp;
        }
      );

      apps = forAllSystems (
        system:
        let
          app = {
            type = "app";
            program = lib.getExe self.packages.${system}.default;
          };
        in
        {
          vite-plus = app;
          default = app;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      overlays.default = final: prev: {
        vite-plus = self.packages.${final.system}.vite-plus;
      };

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nodejs
              pkgs.pnpm_10
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          vite-plus-version = pkgs.runCommand "vite-plus-version-check" { } ''
            # vp builds an HTTPS client on startup and aborts when no CA certs
            # are found (a hard error on Linux), so point it at a bundle.
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            ${self.packages.${system}.vite-plus}/bin/vp --version
            touch $out
          '';
        }
      );
    };
}
