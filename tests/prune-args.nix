# The forget arguments of a job with the default policy, pinned: grouped by
# host only, on NixOS (modules/restic-s3.nix) and nix-darwin
# (modules/darwin/restic-s3-config.nix) alike. Evaluation only.
# `nix build .#checks.<system>.prune-args`.
{ pkgs }:
let
  policy = import ../modules/restic-policy.nix;
  expected = [
    "--group-by host"
    "--keep-daily 7"
    "--keep-weekly 4"
    "--keep-monthly 6"
  ];
  shared = import ../modules/restic-prune-args.nix policy;
  darwin =
    (import ../modules/darwin/restic-s3-config.nix {
      name = "t";
      stateDir = "/state";
      textfileDir = "/textfile";
      job = policy // {
        paths = [ "/src" ];
      };
    }).pruneArgs;
  check =
    what: got:
    if got == expected then
      true
    else
      throw "${what}: ${builtins.toJSON got}, expected ${builtins.toJSON expected}";
in
assert check "modules/restic-prune-args.nix" shared;
assert check "modules/darwin/restic-s3-config.nix" darwin;
pkgs.runCommand "prune-args" { } "touch $out"
