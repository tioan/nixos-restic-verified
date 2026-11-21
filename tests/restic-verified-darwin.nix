# modules/restic-verified.sh the way modules/darwin/restic-s3.nix runs it on
# nix-darwin: `run` only, no systemd, no inputs, the paths as arguments
# instead of --files-from, the config from modules/darwin/restic-s3-config.nix.
# Against a local repository:
#  - a good run is verified (metrics: failed 0, a timestamp, the snapshot),
#  - a required path that is missing fails the run with reason `source`,
#    and the metrics say so,
#  - the next good run clears it again.
# Runs on both systems: `nix build .#checks.<system>.restic-verified-darwin`.
{ pkgs }:
let
  policy = import ../modules/restic-policy.nix;
  verified = pkgs.writeShellApplication {
    name = "restic-verified";
    runtimeInputs = [
      pkgs.restic
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
    ];
    text = import ../modules/restic-verified-script.nix { inherit (policy) metricPrefix; };
  };
  config =
    root:
    pkgs.writeText "restic-verified-t.json" (
      builtins.toJSON (
        import ../modules/darwin/restic-s3-config.nix {
          name = "t";
          stateDir = "${root}/state";
          textfileDir = "${root}/textfile";
          job = policy // {
            paths = [
              "${root}/src/dir"
              "${root}/src/file"
            ];
          };
        }
      )
    );
in
pkgs.runCommand "restic-verified-darwin"
  {
    nativeBuildInputs = [
      pkgs.restic
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail
    # The build directory differs from the paths baked into the config, so
    # work under a fixed root.
    root=/tmp/rvd
    export HOME=$TMPDIR
    mkdir -p $root/src/dir $root/state $root/textfile
    echo a > $root/src/dir/a
    echo b > $root/src/file
    export RESTIC_REPOSITORY=$root/repo RESTIC_PASSWORD=test RESTIC_CACHE_DIR=$TMPDIR/cache
    restic init -q
    cfg=${config "/tmp/rvd"}
    m=$root/textfile/restic-verified-t.prom

    ${pkgs.lib.getExe verified} run "$cfg"
    grep -qx 'nixlab_backup_last_run_failed{backup="t",reason=""} 0' $m
    ! grep -q 'nixlab_backup_verified_timestamp_seconds{backup="t"} 0$' $m
    grep -q 'nixlab_backup_verified_snapshot_info{backup="t",snapshot=' $m

    rm $root/src/file
    if ${pkgs.lib.getExe verified} run "$cfg"; then
      echo "a run without a required path was verified" >&2
      exit 1
    fi
    grep -q 'nixlab_backup_last_run_failed{backup="t",reason="source[^"]*"} 1' $m

    echo b > $root/src/file
    ${pkgs.lib.getExe verified} run "$cfg"
    grep -qx 'nixlab_backup_last_run_failed{backup="t",reason=""} 0' $m

    rm -rf $root
    touch $out
  ''
