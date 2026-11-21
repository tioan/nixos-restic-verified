{
  description = "restic backups that only count once verified: NixOS and nix-darwin modules for S3 jobs, with btrfs snapshots and Prometheus textfile metrics";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      forSystems = systems: f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # restic-s3 imports restic-verified; restic-s3-sops imports restic-s3.
      nixosModules = {
        restic-verified = ./modules/restic-verified.nix;
        restic-s3 = ./modules/restic-s3.nix;
        restic-s3-sops = ./modules/restic-s3-sops.nix;
        default = ./modules/restic-s3.nix;
      };

      darwinModules = {
        restic-s3 = ./modules/darwin/restic-s3.nix;
        restic-s3-sops = ./modules/darwin/restic-s3-sops.nix;
        default = ./modules/darwin/restic-s3.nix;
      };

      lib = {
        # btrfsSnapshots { inherit pkgs; } [ { from = "/"; to = "/snapshots/x"; } ]
        #   -> { prepare, cleanup }, see modules/restic-btrfs-snapshots.nix.
        btrfsSnapshots = import ./modules/restic-btrfs-snapshots.nix;
      };

      checks =
        forSystems [ "x86_64-linux" "aarch64-darwin" ] (pkgs: {
          # The script as nix-darwin runs it, against a local repository.
          restic-verified-darwin = import ./tests/restic-verified-darwin.nix { inherit pkgs; };
          # The forget arguments, grouped by host on both systems.
          prune-args = import ./tests/prune-args.nix { inherit pkgs; };
        })
        // {
          x86_64-linux =
            let
              pkgs = nixpkgs.legacyPackages.x86_64-linux;
            in
            {
              restic-verified-darwin = import ./tests/restic-verified-darwin.nix { inherit pkgs; };
              prune-args = import ./tests/prune-args.nix { inherit pkgs; };
              # NixOS VM tests: forced failures, and the exporter's read-only key against Garage.
              restic-verified = import ./tests/restic-verified.nix { inherit pkgs; };
              restic-exporter-readonly = import ./tests/restic-exporter-readonly.nix { inherit pkgs; };
            };
        };

      formatter = forSystems [ "x86_64-linux" "aarch64-darwin" ] (pkgs: pkgs.nixfmt-tree);
    };
}
