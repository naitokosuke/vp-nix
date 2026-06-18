{
  description = "Unofficial personal Nix flake for Vite+ - Unified Toolchain for JavaScript";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = lib.genAttrs supportedSystems;

      pkgsFor = system: nixpkgs.legacyPackages.${system};

      mkVitePlus =
        system:
        let
          pkgs = pkgsFor system;
          nodejs = pkgs.nodejs_24;
          version = "0.2.0";

          # Upstream ships prebuilt per-platform binaries on npm via
          # optionalDependencies (@voidzero-dev/vite-plus-<platform>: a napi
          # .node plus a JS bin/vp launcher). pnpm fetches the one matching the
          # build platform, so no Rust toolchain / cargo build is needed.
          nodeModules = pkgs.stdenv.mkDerivation {
            pname = "vite-plus-node-modules";
            inherit version;
            src = ./pnpm;

            nativeBuildInputs = [
              pkgs.pnpm_10
              pkgs.pnpmConfigHook
            ];

            pnpmDeps = pkgs.fetchPnpmDeps {
              pname = "vite-plus-node-modules";
              inherit version;
              src = ./pnpm;
              hash = "sha256-Y8JpqrC3jbtfH08INv9GhBArnALoBE9P5blLcIuKwJ4="; # pnpmDepsHash
              fetcherVersion = 3;
            };

            dontBuild = true;

            installPhase = ''
              mkdir -p $out
              cp -r node_modules $out/
            '';
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "vite-plus";
          inherit version;

          dontUnpack = true;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib $out/bin
            cp -r ${nodeModules}/node_modules $out/lib/node_modules

            # The store pins files to 0444, but `vp create` copies templates
            # with fs.copyFileSync (mode-preserving) and then editJsonFile fails
            # with EACCES on the read-only copy. Chmod each copied file to 0644.
            substituteInPlace $out/lib/node_modules/vite-plus/dist/create/bin.js \
              --replace-fail 'else fs.copyFileSync(src, dest);' \
                             'else { fs.copyFileSync(src, dest); fs.chmodSync(dest, 0o644); }'

            for b in vp oxfmt oxlint; do
              makeWrapper ${nodejs}/bin/node $out/bin/$b \
                --add-flags $out/lib/node_modules/vite-plus/bin/$b
            done

            runHook postInstall
          '';

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
              pkgs.nodejs_24
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
