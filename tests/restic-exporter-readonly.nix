# The restic exporter with a read-only key of its own (modules/restic-s3.nix
# and modules/restic-s3-sops.nix, exporter.ownKey), against a real Garage: the
# exporter's collection - `restic check` included, restic_check_success is
# what a "check failed" alert reads - must work with a key that may only read
# the bucket, and that key must not be able to write or delete anything there.
#
# The module is the real one. sops is replaced by a stand-in below that
# installs the secrets from plain files the test writes and renders the
# templates the same way, with the owners and modes the module asks for (none: root-only).
# A throwaway VM, no real secrets.
{ pkgs }:
let
  bucket = "t-backups";
  secretsDir = "/var/lib/test-secrets";

  # Just enough of sops-nix's interface for modules/restic-s3-sops.nix:
  # sops.secrets.<name>.path, sops.templates.<name>.{content,path,owner,
  # group,mode} and sops.placeholder.<name>. The sops-stub unit installs
  # /run/secrets/<name> from ${secretsDir}/<name>.
  sopsStub =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      entry =
        dir:
        lib.types.submodule (
          { name, ... }: {
            freeformType = lib.types.attrsOf lib.types.anything;
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                default = "${dir}/${name}";
              };
              owner = lib.mkOption {
                type = lib.types.str;
                default = "root";
              };
              group = lib.mkOption {
                type = lib.types.str;
                default = "root";
              };
              mode = lib.mkOption {
                type = lib.types.str;
                default = "0400";
              };
            };
          }
        );
      install = e: "install -D -m ${e.mode} -o ${e.owner} -g ${e.group} /dev/stdin ${e.path}";
    in
    {
      options.sops = {
        secrets = lib.mkOption {
          type = lib.types.attrsOf (entry "/run/secrets");
          default = { };
        };
        templates = lib.mkOption {
          type = lib.types.attrsOf (entry "/run/secrets/rendered");
          default = { };
        };
        placeholder = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = lib.mapAttrs (name: _: "<SOPS:${name}>") config.sops.secrets;
        };
      };
      config.systemd.services.sops-stub = {
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script =
          lib.concatStrings (
            lib.mapAttrsToList (name: e: ''
              ${install e} < ${secretsDir}/${name}
            '') config.sops.secrets
          )
          + lib.concatStrings (
            lib.mapAttrsToList (name: t: ''
              content=$(cat ${pkgs.writeText "template-${name}" t.content})
              ${lib.concatStrings (
                lib.mapAttrsToList (s: p: ''
                  content=''${content//"${p}"/"$(cat ${secretsDir}/${s})"}
                '') config.sops.placeholder
              )}
              printf '%s\n' "$content" | ${install t}
            '') config.sops.templates
          );
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "restic-exporter-readonly";

  nodes.machine = { lib, pkgs, ... }: {
    imports = [
      ../modules/restic-s3-sops.nix
      sopsStub
    ];

    virtualisation.memorySize = 2048;
    environment.systemPackages = [
      pkgs.restic
      pkgs.curl
      pkgs.jq
    ];

    # Garage 2, single node.
    services.garage = {
      enable = true;
      package = pkgs.garage_2;
      settings = {
        replication_factor = 1;
        db_engine = "sqlite";
        rpc_bind_addr = "127.0.0.1:3901";
        rpc_secret = "0000000000000000000000000000000000000000000000000000000000000000";
        s3_api = {
          s3_region = "garage";
          api_bind_addr = "127.0.0.1:3900";
        };
      };
    };

    systemd.tmpfiles.rules = [ "f /data/file 0644 root root - restic exporter test" ];

    services.resticS3 = {
      endpoint = "http://127.0.0.1:3900";
      region = "garage";
      jobs.t = {
        inherit bucket;
        paths = [ "/data" ];
        time = "02:30";
      };
      exporter.job = "t";
      exporter.ownKey = true;
    };

    # The exporter on the job's own key, as hosts without a key of its own
    # run it (root-only secrets work there too).
    specialisation.sharedKey.configuration.services.resticS3.exporter.ownKey = lib.mkForce false;
  };

  testScript = ''
    import re

    SECRETS = "${secretsDir}"
    REPO = "s3:http://127.0.0.1:3900/${bucket}"
    METRICS = "curl -sf http://127.0.0.1:9753/metrics"

    def field(label: str, text: str) -> str:
        m = re.search(label + r":\s*(\S+)", text)
        assert m is not None, f"no {label} in garage's output"
        return m.group(1)

    def key(name: str) -> tuple[str, str]:
        out = machine.succeed(f"garage key create {name}")
        return (field("Key ID", out), field("Secret key", out))

    def secret(name, value):
        machine.succeed(f"printf '%s' '{value}' | install -D -m 0400 /dev/stdin {SECRETS}/{name}")

    def as_key(k: tuple[str, str], cmd: str) -> str:
        return (f"AWS_ACCESS_KEY_ID={k[0]} AWS_SECRET_ACCESS_KEY={k[1]} "
                f"AWS_DEFAULT_REGION=garage RESTIC_REPOSITORY={REPO} "
                f"RESTIC_PASSWORD_FILE=/run/secrets/restic_t_password {cmd}")

    def s3(k: tuple[str, str], method: str, obj: str) -> str:
        return machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -X {method} --aws-sigv4 aws:amz:garage:s3 "
            f"--user {k[0]}:{k[1]} http://127.0.0.1:3900/${bucket}/{obj}"
            + (" --data-binary probe" if method == "PUT" else "")).strip()

    def snapshots(k: tuple[str, str]) -> int:
        return len(machine.succeed(as_key(k, "restic snapshots --json | jq -c '.[]'")).splitlines())

    machine.wait_for_unit("garage.service")
    machine.wait_for_open_port(3901, "127.0.0.1")

    with subtest("Garage: one bucket, a read/write and a read-only key"):
        node = machine.succeed("garage node id -q").strip().split("@")[0]
        machine.succeed(f"garage layout assign -z dc1 -c 1G {node}")
        machine.succeed("garage layout apply --version 1")
        machine.succeed("garage bucket create ${bucket}")
        rw = key("t-backup")
        ro = key("t-backup-exporter")
        machine.succeed("garage bucket allow --read --write ${bucket} --key t-backup")
        machine.succeed("garage bucket allow --read ${bucket} --key t-backup-exporter")
        machine.wait_for_open_port(3900, "127.0.0.1")

    with subtest("Secrets in place, both S3 environments root-only"):
        secret("restic_t_password", "test")
        secret("restic_t_key_id", rw[0])
        secret("restic_t_secret_key", rw[1])
        secret("restic_exporter_key_id", ro[0])
        secret("restic_exporter_secret_key", ro[1])
        machine.succeed("systemctl start sops-stub.service")
        # The exporter runs under a dynamic user, but systemd reads the
        # credential and the environment file as root: no group needed.
        for f in ["restic_t_password", "rendered/restic-t-s3-env", "rendered/restic-exporter-s3-env"]:
            t.assertEqual(machine.succeed(f"stat -c '%U:%G %a' /run/secrets/{f}").strip(), "root:root 400")
        t.assertIn(f"AWS_ACCESS_KEY_ID={ro[0]}", machine.succeed("cat /run/secrets/rendered/restic-exporter-s3-env"))

    with subtest("A backup with the job's key"):
        machine.succeed(as_key(rw, "restic init"))
        machine.succeed("systemctl start restic-backups-t.service")
        t.assertEqual(snapshots(rw), 1)

    with subtest("The exporter collects everything with the read-only key, check included"):
        machine.succeed("systemctl restart prometheus-restic-exporter.service")
        machine.wait_until_succeeds(f"{METRICS} | grep -q '^restic_check_success 1.0'", timeout=180)
        machine.succeed(f"{METRICS} | grep -q '^restic_snapshots_total 1.0'")
        machine.succeed(f"{METRICS} | grep -q '^restic_locks_total 0.0'")
        pid = machine.succeed("systemctl show -p MainPID --value prometheus-restic-exporter").strip()
        t.assertIn(f"AWS_ACCESS_KEY_ID={ro[0]}", machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ"))
        machine.fail("journalctl -u prometheus-restic-exporter -o cat | grep -iE 'AccessDenied|permission denied|Fatal'")

    with subtest("The read-only key can neither write nor delete"):
        t.assertEqual(s3(ro, "PUT", "probe"), "403")
        t.assertEqual(s3(ro, "DELETE", "config"), "403")
        machine.fail(as_key(ro, "restic forget --keep-last 1 --prune"))
        machine.fail(as_key(ro, "restic backup /data"))
        # The repository is untouched - and the read/write key could have.
        machine.succeed(as_key(rw, "restic check"))
        t.assertEqual(snapshots(rw), 1)
        t.assertEqual(s3(rw, "PUT", "probe"), "200")
        t.assertEqual(s3(rw, "DELETE", "probe"), "204")

    with subtest("Without a key of its own the exporter runs on the job's key, still root-only"):
        machine.succeed("/run/booted-system/specialisation/sharedKey/bin/switch-to-configuration test")
        machine.succeed("systemctl restart sops-stub.service")
        for f in ["restic_t_password", "rendered/restic-t-s3-env"]:
            t.assertEqual(machine.succeed(f"stat -c '%U:%G %a' /run/secrets/{f}").strip(), "root:root 400")
        machine.succeed("systemctl restart prometheus-restic-exporter.service")
        machine.wait_until_succeeds(f"{METRICS} | grep -q '^restic_check_success 1.0'", timeout=180)
        machine.succeed(f"{METRICS} | grep -q '^restic_snapshots_total 1.0'")
        pid = machine.succeed("systemctl show -p MainPID --value prometheus-restic-exporter").strip()
        t.assertIn(f"AWS_ACCESS_KEY_ID={rw[0]}", machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ"))
        machine.fail("journalctl -u prometheus-restic-exporter -o cat | grep -iE 'AccessDenied|permission denied|Fatal'")
        t.assertNotIn("restic-metrics", machine.succeed("systemctl show -p SupplementaryGroups --value prometheus-restic-exporter"))
  '';
}
