# Runs and verifies one restic job, see modules/restic-verified.nix.
#
#   restic-verified run     <config.json>  the job's ExecStart
#   restic-verified stop    <config.json>  the job's ExecStopPost
#   restic-verified retry   <config.json>  start the job unless it is verified
#   restic-verified metrics <config.json>  (re)write the textfile metrics
#
# Never print what restic lists: file names in a repository can be private
# (scanned documents, mail). Only IDs, counts, sizes and reason classes go to the
# journal and the metrics.

command=$1
config=$2

name=$(jq -r .name "$config")
state_dir=$(jq -r .stateDir "$config")
textfile_dir=$(jq -r .textfileDir "$config")
state_file="$state_dir/$name.json"
failed_file="$state_dir/$name.failed"
# IDs of this job's snapshots that failed a check after the backup and do not
# carry the `unverified` tag yet. No forget runs while one is left.
untagged_file="$state_dir/$name.untagged"
# Snapshots were forgotten, their data not pruned yet.
prune_file="$state_dir/$name.prune-pending"
unit="restic-backups-$name.service"

write_metrics() {
  local timestamp=0 files=0 bytes=0 snapshot="" failed=0 reason="" tmp
  if [ -s "$state_file" ]; then
    timestamp=$(jq -r .timestamp "$state_file")
    files=$(jq -r .files "$state_file")
    bytes=$(jq -r .bytes "$state_file")
    snapshot=$(jq -r .snapshot "$state_file")
  fi
  if [ -e "$failed_file" ]; then
    failed=1
    reason=$(cat "$failed_file")
  fi

  mkdir -p "$textfile_dir"
  # No .prom suffix until complete: the collector only reads *.prom.
  tmp=$(mktemp "$textfile_dir/.restic-verified-$name.XXXXXX")
  {
    echo "# HELP @metricPrefix@backup_verified_timestamp_seconds Finish time of the newest verified backup, 0 if there is none."
    echo "# TYPE @metricPrefix@backup_verified_timestamp_seconds gauge"
    echo "@metricPrefix@backup_verified_timestamp_seconds{backup=\"$name\"} $timestamp"
    echo "# HELP @metricPrefix@backup_last_run_failed 1 from a failed run until the next verified one. Survives switches."
    echo "# TYPE @metricPrefix@backup_last_run_failed gauge"
    echo "@metricPrefix@backup_last_run_failed{backup=\"$name\",reason=\"$reason\"} $failed"
    echo "# HELP @metricPrefix@backup_verified_files Files processed by the newest verified backup."
    echo "# TYPE @metricPrefix@backup_verified_files gauge"
    echo "@metricPrefix@backup_verified_files{backup=\"$name\"} $files"
    echo "# HELP @metricPrefix@backup_verified_bytes Bytes processed by the newest verified backup."
    echo "# TYPE @metricPrefix@backup_verified_bytes gauge"
    echo "@metricPrefix@backup_verified_bytes{backup=\"$name\"} $bytes"
    if [ -n "$snapshot" ]; then
      echo "# HELP @metricPrefix@backup_verified_snapshot_info Short ID of the newest verified snapshot."
      echo "# TYPE @metricPrefix@backup_verified_snapshot_info gauge"
      echo "@metricPrefix@backup_verified_snapshot_info{backup=\"$name\",snapshot=\"$snapshot\"} 1"
    fi
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$textfile_dir/restic-verified-$name.prom"
}

# A source counts only if it holds something: restic with --files-from skips a
# missing path and still exits 0, and an empty directory is a valid backup.
source_has_content() {
  local path=$1
  if [ -d "$path" ]; then
    [ -n "$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" ]
  else
    [ -s "$path" ]
  fi
}

record_failure() {
  # Unique classes, comma-separated, usable as a label value.
  printf '%s\n' "$@" | sort -u | paste -sd, >"$failed_file"
  write_metrics
  echo "backup $name NOT verified: $(cat "$failed_file")" >&2
}

# Adds to the caller's `reasons`.
verify_snapshot() {
  local id=$1 started=$2 snapshot time epoch last_files last_bytes min_percent path count want
  if ! snapshot=$(restic snapshots --no-lock --json "$id" 2>/dev/null) ||
    [ "$(jq 'length' <<<"$snapshot")" != 1 ]; then
    reasons+=(verify-snapshot)
    return
  fi

  time=$(jq -r '.[0].time' <<<"$snapshot")
  epoch=$(date -d "$time" +%s)
  if [ "$epoch" -lt "$((started - 60))" ]; then
    reasons+=(verify-snapshot)
  fi

  files=$(jq -r '.[0].summary.total_files_processed // 0' <<<"$snapshot")
  bytes=$(jq -r '.[0].summary.total_bytes_processed // 0' <<<"$snapshot")
  if [ "$files" -eq 0 ] || [ "$bytes" -eq 0 ]; then
    reasons+=(verify-size)
  elif [ -s "$state_file" ]; then
    last_files=$(jq -r .files "$state_file")
    last_bytes=$(jq -r .bytes "$state_file")
    min_percent=$(jq -r .minPercent "$config")
    if [ "$((files * 100))" -lt "$((last_files * min_percent))" ] ||
      [ "$((bytes * 100))" -lt "$((last_bytes * min_percent))" ]; then
      reasons+=(verify-size)
    fi
  fi

  # Read back from the repository, counted and never printed. A directory
  # lists itself plus its children, so an empty one comes to 1.
  while IFS= read -r path; do
    want=1
    if [ -d "$path" ]; then want=2; fi
    if ! count=$(restic ls --no-lock --json "$id" "$path" 2>/dev/null |
      jq -Rc 'fromjson? | select(.struct_type == "node") | 1' | wc -l); then
      count=0
    fi
    if [ "$count" -lt "$want" ]; then
      echo "not in snapshot $id: $path" >&2
      reasons+=(verify-path)
    fi
  done < <(jq -r '.requiredPaths[]' "$config")

  # Sundays also read a sample of the data, the other nights only structure.
  local check_args=()
  if [ "$(date +%u)" = 7 ]; then
    check_args=("--read-data-subset=$(jq -r .checkSubset "$config")")
  fi
  if ! restic check --no-lock "${check_args[@]}" >/dev/null; then
    reasons+=(check)
  fi
}

run() {
  local started reasons=() path input stamp max_age summary rc id files=0 bytes=0
  local tag_args=() backup_args=() prune_args=()
  started=$(date +%s)

  while IFS= read -r path; do
    if ! source_has_content "$path"; then
      echo "source missing or empty: $path" >&2
      reasons+=(source)
    fi
  done < <(jq -r '.requiredPaths[]' "$config")

  max_age=$(($(jq -r .maxAgeHours "$config") * 3600))
  while IFS= read -r input; do
    stamp="$state_dir/stamps/$input"
    # Separate messages: no stamp says nothing about the input's age. It is also
    # what a job reports between deploying a new input and that input's next run.
    if [ ! -e "$stamp" ]; then
      echo "input has no stamp, no successful run recorded: $input" >&2
      reasons+=(input)
    elif [ "$((started - $(date -r "$stamp" +%s)))" -gt "$max_age" ]; then
      echo "input not fresh: $input" >&2
      reasons+=(input)
    fi
  done < <(jq -r '.inputs[]' "$config")

  # Store anyway: one bad part must not cost the night's other new data. The
  # tag is set at creation because an append-only repository cannot change a
  # snapshot afterwards.
  if [ "${#reasons[@]}" -gt 0 ]; then
    tag_args=(--tag unverified)
  fi

  while IFS= read -r line; do
    read -ra words <<<"$line"
    backup_args+=("${words[@]}")
  done < <(jq -r '.backupArgs[]' "$config")

  # Only the summary is kept: progress lines name the files being read.
  summary=$(mktemp)
  set +e
  restic backup --json "${tag_args[@]}" "${backup_args[@]}" |
    jq -Rc 'fromjson? | select(.message_type == "summary")' >"$summary"
  rc=${PIPESTATUS[0]}
  set -e

  # 3: snapshot written, but some source files could not be read.
  if [ "$rc" = 3 ]; then
    reasons+=(backup-partial)
  elif [ "$rc" != 0 ]; then
    rm -f "$summary"
    reasons+=("backup-exit-$rc")
    record_failure "${reasons[@]}"
    return 1
  fi

  id=$(jq -r '.snapshot_id // empty' "$summary" | tail -n 1)
  rm -f "$summary"
  # Queued for the tag until verified: a run stopped during the checks below
  # must not leave an untagged snapshot that forget counts as verified. Only
  # where forget runs at all: an append-only repository cannot change a
  # snapshot.
  if [ -n "$id" ] && [ "${#tag_args[@]}" -eq 0 ] && [ "$(jq '.pruneArgs | length' "$config")" -gt 0 ]; then
    echo "$id" >>"$untagged_file"
  fi
  if [ -z "$id" ]; then
    reasons+=(verify-snapshot)
  else
    verify_snapshot "$id" "$started"
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    # No forget/prune: bad snapshots must not push good ones out.
    echo "snapshot ${id:-none} stored, files=$files bytes=$bytes" >&2
    # This run's snapshot, if it failed only the checks after the backup, is
    # queued above.
    if ! tag_untagged; then
      reasons+=(tag)
    fi
    record_failure "${reasons[@]}"
    return 1
  fi

  jq -n --arg snapshot "$id" --argjson timestamp "$(date +%s)" \
    --argjson files "$files" --argjson bytes "$bytes" \
    '{$snapshot, $timestamp, $files, $bytes}' >"$state_file.tmp"
  mv -f "$state_file.tmp" "$state_file"
  if [ -e "$untagged_file" ]; then
    grep -vx -- "$id" "$untagged_file" >"$untagged_file.tmp" || true
    if [ -s "$untagged_file.tmp" ]; then
      mv -f "$untagged_file.tmp" "$untagged_file"
    else
      rm -f "$untagged_file.tmp" "$untagged_file"
    fi
  fi
  rm -f "$failed_file"
  write_metrics
  echo "backup $name verified: snapshot $id, files=$files bytes=$bytes"

  while IFS= read -r line; do
    read -ra words <<<"$line"
    prune_args+=("${words[@]}")
  done < <(jq -r '.pruneArgs[]' "$config")
  if [ "${#prune_args[@]}" -gt 0 ]; then
    if ! restic unlock >/dev/null || ! forget_and_prune "${prune_args[@]}"; then
      # The backup itself is verified, the repository still needs attention.
      record_failure prune
      return 1
    fi
  fi
}

# 0 if the repository holds a snapshot whose ID starts with $1, 1 if not, 2 if
# it cannot be read. `list` reads the snapshot files' names; `snapshots` would
# leave out one it cannot load, with a warning and exit 0.
snapshot_exists() {
  local all
  all=$(restic list snapshots --no-lock) || return 2
  grep -q "^$1" <<<"$all"
}

# Fails if any of the given snapshots still exists, or that cannot be told:
# restic 0.18.1's `forget` only logs a snapshot it could not remove.
all_gone() {
  local all id
  [ "$#" -gt 0 ] || return 0
  if ! all=$(restic list snapshots --no-lock); then
    echo "repository cannot be listed to confirm removals" >&2
    return 1
  fi
  for id in "$@"; do
    if grep -q "^$id" <<<"$all"; then
      echo "snapshot not removed: $id" >&2
      return 1
    fi
  done
}

# Tags the snapshots in untagged_file. restic 0.18.1's `tag` saves a tagged
# copy, then removes the original, and exits 0 even when one of the two
# failed. So done means: the original ID is gone. Run again, it tags whatever
# is left; a second tagged copy is harmless.
tag_untagged() {
  local id rc left=()
  if [ ! -s "$untagged_file" ]; then
    # Also clears an empty queue that an earlier version left behind.
    rm -f "$untagged_file"
    return 0
  fi
  while read -r id; do
    snapshot_exists "$id" && rc=0 || rc=$?
    if [ "$rc" = 0 ]; then
      restic tag --add unverified "$id" >/dev/null || true
      snapshot_exists "$id" && rc=0 || rc=$?
    fi
    if [ "$rc" != 1 ]; then
      left+=("$id")
    fi
  done <"$untagged_file"
  if [ "${#left[@]}" -gt 0 ]; then
    # Replaced, never truncated first: a run killed in between must not lose
    # IDs, or forget would count those snapshots as verified.
    printf '%s\n' "${left[@]}" >"$untagged_file.tmp" &&
      mv -f "$untagged_file.tmp" "$untagged_file"
    echo "snapshots still without the unverified tag: ${left[*]}" >&2
    return 1
  fi
  rm -f "$untagged_file"
}

# The job's policy applies to verified snapshots only. Unverified ones
# would otherwise take its daily and weekly slots: restic counts a snapshot
# towards every bucket it falls into, --keep-tag included (tested with 0.18.1).
# `--tag ''` selects snapshots without any tag; `unverified` is the only tag
# a job may carry (modules/restic-verified.nix asserts that, and that the job
# has its own repository and the host's name). Unverified snapshots age out by
# their own date instead: --keep-within counts from the group's newest
# snapshot, not from now, so it would never remove the last of them.
#
# The prune options among the job's pruneOpts go to the final prune as well,
# which `forget --prune` used to run with them. Like `forget --prune`, prune
# runs only when something was forgotten. The marker is written before any
# forget and left in place until prune succeeded, so a run that stops in
# between leaves the prune to the next one.
#
# Called in a condition, where set -e does not apply: every step checks itself.
forget_and_prune() {
  local keep_days cutoff plan removed_ids expiring unverified id time owed=0 removed=() old=() prune_opts=() args=("$@") i
  tag_untagged || return 1

  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
    --max-unused | --max-repack-size | --repack-smaller-than)
      prune_opts+=("${args[i]}" "${args[i + 1]:-}")
      i=$((i + 1))
      ;;
    --max-unused=* | --max-repack-size=* | --repack-smaller-than=* | --repack-cacheable-only* | --repack-small | --repack-small=* | --repack-uncompressed*)
      prune_opts+=("${args[i]}")
      ;;
    esac
  done

  if [ -e "$prune_file" ]; then owed=1; fi
  touch "$prune_file" || return 1

  plan=$(restic forget --json --tag '' "$@") || return 1
  # pruneOpts cannot switch JSON off or add --prune (modules/restic-verified.nix),
  # and a plan that does not decode stops here: an empty list would skip prune.
  removed_ids=$(jq -r '.[]? | (.remove // [])[] | .id' <<<"$plan") || return 1
  mapfile -t removed <<<"$removed_ids"
  if [ -z "$removed_ids" ]; then removed=(); fi
  all_gone "${removed[@]}" || return 1

  keep_days=$(jq -r .keepUnverifiedDays "$config")
  cutoff=$(($(date +%s) - keep_days * 86400))
  unverified=$(restic snapshots --no-lock --json --host "$(uname -n)" --tag unverified) || return 1
  expiring=$(jq -r '.[] | "\(.id) \(.time)"' <<<"$unverified") || return 1
  while read -r id time; do
    [ -n "$id" ] || continue
    if [ "$(date -d "$time" +%s)" -lt "$cutoff" ]; then
      old+=("$id")
    fi
  done < <(printf '%s\n' "$expiring")
  if [ "${#old[@]}" -gt 0 ]; then
    echo "forgetting ${#old[@]} unverified snapshots older than $keep_days days"
    restic forget "${old[@]}" >/dev/null || return 1
    all_gone "${old[@]}" || return 1
  fi

  if [ "$owed" = 1 ] || [ "${#removed[@]}" -gt 0 ] || [ "${#old[@]}" -gt 0 ]; then
    restic prune "${prune_opts[@]}" >/dev/null || return 1
  fi
  rm -f "$prune_file"
}

stop() {
  # A run that got as far as its own verdict has written it. Everything else
  # (prepare step failed, killed by a reboot) is caught here.
  if [ "${SERVICE_RESULT:-success}" != success ] && [ ! -e "$failed_file" ]; then
    echo "unit-${SERVICE_RESULT}" >"$failed_file"
  fi
  write_metrics
}

retry() {
  local timestamp=0 max_age
  if systemctl is-active --quiet "$unit"; then
    return 0
  fi
  if [ -s "$state_file" ]; then
    timestamp=$(jq -r .timestamp "$state_file")
  fi
  max_age=$(jq -r .retryIfOlderThanHours "$config")
  if [ ! -e "$failed_file" ] && [ "$(($(date +%s) - timestamp))" -lt "$((max_age * 3600))" ]; then
    return 0
  fi
  echo "backup $name is not verified, starting it again"
  systemctl start --no-block "$unit"
}

case "$command" in
run) run ;;
stop) stop ;;
retry) retry ;;
metrics) write_metrics ;;
*)
  echo "unknown command: $command" >&2
  exit 2
  ;;
esac
