# Forced failures for modules/restic-verified.nix: each must end unverified,
# and only a good run may end verified. Plus a series of nights for its
# forget (unverified snapshots must not take a verified one's keep slot). A
# throwaway VM with local repositories, no secrets.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "restic-verified";

  nodes.machine = { pkgs, ... }: {
    imports = [ ../modules/restic-verified.nix ];

    environment.systemPackages = [
      pkgs.restic
      pkgs.jq
    ];
    environment.etc."restic-password".text = "test";

    # Stands in for a database dump or an application export. Fails while the flag exists.
    systemd.services.fake-input = {
      serviceConfig.Type = "oneshot";
      script = "test ! -e /run/fail-input";
    };

    services.restic.backups.t = {
      initialize = false;
      repository = "/repo";
      passwordFile = "/etc/restic-password";
      paths = [
        "/data/dir"
        "/data/file"
      ];
      exclude = [ "/data/dir/excluded" ];
      pruneOpts = [ "--keep-last 1" ];
      backupPrepareCommand = "test ! -e /run/fail-prepare";
    };
    services.resticVerified.jobs.t.inputs = [ "fake-input" ];

    # A policy with days and weeks, for a series of nights seeded by hand.
    services.restic.backups.s = {
      initialize = false;
      repository = "/repo-s";
      passwordFile = "/etc/restic-password";
      paths = [ "/data/file" ];
      pruneOpts = [
        "--keep-daily 3"
        "--keep-weekly 2"
      ];
    };
    services.resticVerified.jobs.s = { };
  };

  testScript = ''
    import json

    PROM = "/var/lib/prometheus-node-exporter-text-files/restic-verified-t.prom"
    REPO = "RESTIC_REPOSITORY=/repo RESTIC_PASSWORD_FILE=/etc/restic-password"

    def metric(name):
        line = machine.succeed(f"grep '^{name}' {PROM}").strip()
        return float(line.rsplit(" ", 1)[1])

    def reason():
        line = machine.succeed(f"grep '^nixlab_backup_last_run_failed' {PROM}")
        return line.split('reason="', 1)[1].split('"', 1)[0]

    def snapshots(repo=REPO):
        return json.loads(machine.succeed(f"{repo} restic snapshots --json"))

    def unverified(snapshot):
        return "unverified" in (snapshot.get("tags") or [])

    def backup_fails(expected):
        verified_before = metric("nixlab_backup_verified_timestamp_seconds")
        machine.fail("systemctl start restic-backups-t.service")
        assert metric("nixlab_backup_last_run_failed") == 1
        assert expected in reason(), f"{expected} not in {reason()}"
        assert metric("nixlab_backup_verified_timestamp_seconds") == verified_before

    # Scoped to the newest run: the unit's journal also holds earlier ones.
    def last_run_logs(present, absent):
        invocation = machine.succeed("systemctl show -p InvocationID --value restic-backups-t.service").strip()
        journal = f"journalctl _SYSTEMD_INVOCATION_ID={invocation} -o cat"
        machine.wait_until_succeeds(f"{journal} | grep -q '{present}'")
        machine.fail(f"{journal} | grep -q '{absent}'")

    def backup_verified():
        machine.succeed("sleep 1")
        verified_before = metric("nixlab_backup_verified_timestamp_seconds")
        machine.succeed("systemctl start fake-input.service")
        machine.succeed("systemctl start restic-backups-t.service")
        assert metric("nixlab_backup_last_run_failed") == 0
        assert reason() == ""
        assert metric("nixlab_backup_verified_timestamp_seconds") > verified_before

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "mkdir -p /data/dir/excluded",
        "for i in 1 2 3 4 5 6 7 8; do head -c 4096 /dev/urandom > /data/dir/f$i; done",
        "echo key > /data/file",
        f"{REPO} restic init",
    )

    with subtest("never verified shows as timestamp 0, not as nothing"):
        machine.wait_until_succeeds(f"test -e {PROM}")
        assert metric("nixlab_backup_verified_timestamp_seconds") == 0

    with subtest("a good run is verified and pruned"):
        backup_verified()
        backup_verified()
        assert len(snapshots()) == 1
        assert "unverified" not in (snapshots()[0].get("tags") or [])
        # No queue left behind once the run is verified.
        machine.succeed("test ! -e /var/lib/restic-verified/t.untagged")

    with subtest("input never ran or failed: stored, tagged, not verified, no prune"):
        count = len(snapshots())
        machine.succeed("touch -d '3 days ago' /var/lib/restic-verified/stamps/fake-input")
        backup_fails("input")
        assert len(snapshots()) == count + 1
        assert "unverified" in snapshots()[-1]["tags"]
        last_run_logs("input not fresh: fake-input", "input has no stamp")

        machine.succeed("rm /var/lib/restic-verified/stamps/fake-input")
        backup_fails("input")
        last_run_logs("input has no stamp, no successful run recorded: fake-input", "input not fresh")

        machine.succeed("touch /run/fail-input")
        machine.fail("systemctl start fake-input.service")
        backup_fails("input")
        machine.succeed("rm /run/fail-input")

    with subtest("reset-failed, as every switch does, does not clear the failure"):
        machine.succeed("systemctl reset-failed restic-backups-t.service")
        machine.succeed("systemctl start restic-verified-metrics-t.service")
        assert metric("nixlab_backup_last_run_failed") == 1

    with subtest("a verified run clears it and prune catches up, on verified snapshots only"):
        backup_verified()
        assert len([s for s in snapshots() if not unverified(s)]) == 1
        # The three from above are younger than keepUnverifiedDays.
        assert len([s for s in snapshots() if unverified(s)]) == 3

    with subtest("missing path, which restic itself exits 0 for"):
        machine.succeed("mv /data/file /data/file.away")
        machine.succeed("systemctl start fake-input.service")
        backup_fails("source")
        machine.succeed("mv /data/file.away /data/file")
        backup_verified()

    with subtest("empty directory"):
        machine.succeed("mkdir /data/dir.away && mv /data/dir/* /data/dir.away/")
        backup_fails("source")
        machine.succeed("mv /data/dir.away/* /data/dir/ && rmdir /data/dir.away")
        backup_verified()

    with subtest("source fine, but everything in it excluded from the snapshot"):
        machine.succeed("mkdir /data/dir.away && mv /data/dir/f* /data/dir.away/")
        machine.succeed("head -c 4096 /dev/urandom > /data/dir/excluded/x")
        backup_fails("verify-path")
        assert unverified(snapshots()[-1]), "failed after the backup, but not tagged"
        machine.succeed("mv /data/dir.away/* /data/dir/ && rmdir /data/dir.away")
        machine.succeed("rm /data/dir/excluded/x")
        backup_verified()

    with subtest("much smaller than the last verified one"):
        machine.succeed("mkdir /data/dir.away && mv /data/dir/f[2-8] /data/dir.away/")
        backup_fails("verify-size")
        assert unverified(snapshots()[-1]), "failed after the backup, but not tagged"
        machine.succeed("mv /data/dir.away/* /data/dir/ && rmdir /data/dir.away")
        backup_verified()

    with subtest("target unreachable: nothing stored, no new repository"):
        count = len(snapshots())
        machine.succeed("mv /repo /repo.away")
        backup_fails("backup-exit")
        machine.succeed("test ! -e /repo/config")
        machine.succeed("rm -rf /repo; mv /repo.away /repo")
        assert len(snapshots()) == count
        backup_verified()

    with subtest("prepare step fails: the job never reaches its own verdict"):
        machine.succeed("touch /run/fail-prepare")
        backup_fails("unit-exit-code")
        machine.succeed("rm /run/fail-prepare")
        backup_verified()

    with subtest("repository damaged: restic check fails"):
        machine.succeed("cp -a /repo /repo.good")
        machine.succeed("chmod -R u+w /repo")
        machine.succeed("find /repo/data -type f | head -n 1 | xargs rm -f")
        backup_fails("check")
        machine.succeed("rm -rf /repo; mv /repo.good /repo")
        backup_verified()

    with subtest("unverified nights take no verified snapshot's keep slot, and age out"):
        SERIES = "RESTIC_REPOSITORY=/repo-s RESTIC_PASSWORD_FILE=/etc/restic-password"
        REF = "RESTIC_REPOSITORY=/repo-ref RESTIC_PASSWORD_FILE=/etc/restic-password"
        PLAIN = "RESTIC_REPOSITORY=/repo-plain RESTIC_PASSWORD_FILE=/etc/restic-password"
        POLICY = "--keep-daily 3 --keep-weekly 2"
        machine.succeed(f"{SERIES} restic init")
        now = int(machine.succeed("date +%s"))

        # IDs as short IDs: the backup summary and the snapshot list need not agree
        # on the length. Same host and path as the job's own runs, so forget groups them together.
        def seed(days_ago, tag):
            # Verified nights two hours earlier, so no two snapshots share a time.
            t = now - days_ago * 86400 - (0 if tag else 7200)
            when = machine.succeed(f"date -d @{t} '+%Y-%m-%d %H:%M:%S'").strip()
            args = "--tag unverified" if tag else ""
            out = machine.succeed(f"{SERIES} restic backup --json --host machine {args} --time '{when}' /data/file")
            summary = [json.loads(l) for l in out.splitlines() if '"summary"' in l][-1]
            return summary["snapshot_id"][:8]

        seeded_verified = {seed(d, False) for d in range(30, 14, -1)}
        unverified_old = {seed(d, True) for d in (20, 18)}  # beyond keepUnverifiedDays (14)
        unverified_new = {seed(d, True) for d in range(10, 0, -1)}

        # Reference: the same nights as if the unverified runs never happened.
        # And today's forget without the fix, to show the series exposes it.
        machine.succeed("cp -a /repo-s /repo-ref", "cp -a /repo-s /repo-plain")
        machine.succeed(f"{REF} restic forget -q {' '.join(unverified_old | unverified_new)}")

        machine.succeed("systemctl start restic-backups-s.service")
        machine.succeed(f"{REF} restic backup -q /data/file", f"{PLAIN} restic backup -q /data/file")

        def policy_keeps(repo):
            groups = json.loads(machine.succeed(f"{repo} restic forget --dry-run --json {POLICY}"))
            return {s["id"][:8] for g in groups for s in g["keep"]} & seeded_verified

        after = snapshots(SERIES)
        kept_verified = {s["id"][:8] for s in after if not unverified(s)} & seeded_verified
        kept_unverified = {s["id"][:8] for s in after if unverified(s)}
        assert kept_verified == policy_keeps(REF), f"{kept_verified} != {policy_keeps(REF)}"
        assert policy_keeps(PLAIN) < policy_keeps(REF), "the series does not show the keep-slot problem"
        assert kept_unverified == unverified_new, f"{kept_unverified} != {unverified_new}"
        # And today's verified run itself survives, here as in the reference.
        assert len([s for s in after if not unverified(s) and s["id"][:8] not in seeded_verified]) == 1
        assert len([s for s in snapshots(REF) if s["id"][:8] not in seeded_verified]) == 1

    with subtest("retry starts a failed job, and leaves a verified one alone"):
        before = metric("nixlab_backup_verified_timestamp_seconds")
        machine.succeed("systemctl start restic-verified-retry-t.service")
        machine.sleep(3)
        machine.wait_until_fails("systemctl is-active restic-backups-t.service")
        assert metric("nixlab_backup_verified_timestamp_seconds") == before

        machine.succeed("mv /data/file /data/file.away")
        machine.fail("systemctl start restic-backups-t.service")
        machine.succeed("mv /data/file.away /data/file")
        machine.succeed("systemctl start fake-input.service")
        machine.succeed("systemctl start restic-verified-retry-t.service")
        machine.wait_until_succeeds(f"grep -q 'nixlab_backup_last_run_failed.* 0$' {PROM}", timeout=60)
        assert metric("nixlab_backup_verified_timestamp_seconds") > before
  '';
}
