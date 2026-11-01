{
  description = "Open Design Desktop Companion for Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        pythonEnv = pkgs.python3.withPackages (ps: with ps; [
          pygobject3
          pycairo
        ]);

        runtimeDeps = [
          pythonEnv
          pkgs.nodejs_24
          pkgs.pnpm_10
          pkgs.git
          pkgs.libnotify
          pkgs.gtk4
          pkgs.libadwaita
        ];
      in
      {
        packages.default = pkgs.stdenv.mkDerivation rec {
          pname = "open-design-desktop-linux";
          version = "0.1.0";

          src = ./.;

          nativeBuildInputs = [
            pkgs.wrapGAppsHook4
            pkgs.gobject-introspection
          ];

          buildInputs = runtimeDeps;

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin $out/share/open-design $out/share/applications $out/share/icons/hicolor/512x512/apps

            cp -r assets $out/share/open-design/
            cp open-design $out/share/open-design/open-design
            chmod +x $out/share/open-design/open-design

            cp assets/icon.png $out/share/icons/hicolor/512x512/apps/open_design.png

            substitute open-design.desktop $out/share/applications/open-design.desktop \
              --replace-fail "@ICON_PATH@" "open_design" \
              --replace-fail "@EXEC_PATH@" "$out/bin/open-design" \
              --replace-fail "@STARTUP_WM_CLASS@" "open-design"

            makeWrapper $out/share/open-design/open-design $out/bin/open-design \
              "''${gappsWrapperArgs[@]}" \
              --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Native Linux launcher and updater for Open Design";
            homepage = "https://github.com/ITx-prash/open-design-desktop-linux";
            license = licenses.mit;
            platforms = platforms.linux;
            mainProgram = "open-design";
          };
        };

        apps.default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.default;
        };

        devShells.default = pkgs.mkShell {
          packages = runtimeDeps ++ [
            pkgs.gobject-introspection
          ];
        };
      });
}
