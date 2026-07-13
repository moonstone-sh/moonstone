{
  description = "Moonstone - A next-generation environment manager for Lua";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "moonstone";
          version = "0.4.0"; # Controlled by git tags normally

          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          buildPhase = ''
            # Zig requires a writable cache directory
            export XDG_CACHE_HOME=$(mktemp -d)
            zig build -Doptimize=ReleaseSafe --prefix $out
          '';

          postInstall = ''
            # Nixpkgs standardizes completions into these exact directories.
            # Moonstone will dynamically generate them and inject them during installation.
            $out/bin/moon completions bash > moon.bash
            $out/bin/moon completions zsh > _moon
            $out/bin/moon completions fish > moon.fish

            install -Dm644 moon.bash $out/share/bash-completion/completions/moon
            install -Dm644 _moon $out/share/zsh/site-functions/_moon
            install -Dm644 moon.fish $out/share/fish/vendor_completions.d/moon.fish
          '';
        };

        # This provides a ready-to-go development environment for contributors
        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.zig pkgs.sqlite pkgs.zls ];
        };
      }
    );
}
