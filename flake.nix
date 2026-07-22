{
  description = "Moonstone: Deterministic Lua project environments & multi-platform package realization";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Strictly enforce Zig 0.16 mandatory requirement from nixos-unstable or zig-overlay
        zig =
          if builtins.hasAttr "0.16.0" (zig-overlay.packages.${system} or {}) then
            zig-overlay.packages.${system}."0.16.0"
          else if builtins.hasAttr "zig_0_16" pkgs then
            pkgs.zig_0_16
          else if pkgs.lib.hasPrefix "0.16" (pkgs.zig.version or "") then
            pkgs.zig
          else
            throw "Moonstone strictly requires Zig 0.16. Current nixpkgs provides '${pkgs.zig.version or "unknown"}'.";

        moonstone = pkgs.stdenv.mkDerivation {
          pname = "moonstone";
          version = "0.3.31";

          src = ./.;

          nativeBuildInputs = [
            zig
            pkgs.pkg-config
          ];

          buildInputs = [
            pkgs.sqlite
            pkgs.zstd
          ];

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            zig build -Doptimize=ReleaseSafe --prefix $out
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/moon $out/bin/
          '';

          meta = with pkgs.lib; {
            description = "Deterministic Lua project environments and package manager";
            homepage = "https://moonstone.sh";
            license = licenses.mit;
            mainProgram = "moon";
            platforms = platforms.unix;
          };
        };
      in
      {
        packages = {
          default = moonstone;
          moonstone = moonstone;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = moonstone;
          name = "moon";
        };

        devShells.default = pkgs.mkShell {
          name = "moonstone-dev-shell";

          nativeBuildInputs = with pkgs; [
            zig
            pkg-config
            cmake
            ninja
            gnumake
          ];

          buildInputs = with pkgs; [
            sqlite
            zstd
            lua5_4
            luajit
          ];

          shellHook = ''
            echo "🌙 Welcome to the Moonstone Development Shell (v0.3.31)"
            echo "   Mandatory Compiler: Zig 0.16 ($(zig version))"
            echo "   Run 'zig build test' to execute all unit and integration tests."
          '';
        };
      }
    );
}
