#!/usr/bin/env bash
# Shared local backup helpers for the deployment scripts in this directory.
# SSH must be an array. Archive bytes travel over SSH directly to this machine.

backup_local() (
	local destination="$1" remote_command="$2" partial
	umask 077
	mkdir -p -- "$(dirname -- "$destination")" || exit 1
	[[ ! -e "$destination" && ! -L "$destination" ]] || {
		printf 'Backup already exists: %s\n' "$destination" >&2
		exit 1
	}
	partial=$(mktemp "${destination}.partial.XXXXXX") || exit 1
	trap 'rm -f -- "$partial"' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	if ! "${SSH[@]}" "$remote_command" > "$partial"; then
		printf 'Backup transfer failed; deployment stopped.\n' >&2
		exit 1
	fi
	[[ -s "$partial" ]] || { printf 'Backup is empty; deployment stopped.\n' >&2; exit 1; }
	if [[ "$destination" == *.tgz ]] && ! tar -tzf "$partial" >/dev/null; then
		printf 'Backup archive is invalid; deployment stopped.\n' >&2
		exit 1
	fi
	# Publish only complete backups, atomically, without overwriting an old one.
	ln -- "$partial" "$destination" || exit 1
	ls -lh -- "$destination"
)

local_backup_rollback() {
	printf '%q ' "${SSH[@]}" "$2"
	printf '< %q' "$1"
}

prune_local_backups() {
	python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

directory, service, keep = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
if keep < 1:
	raise SystemExit('At least one backup must be retained')
archives = sorted(
	(path for path in directory.glob(f'{service}-backup-*.tgz')
	 if path.is_file() and not path.is_symlink()),
	key=lambda path: (path.stat().st_mtime_ns, path.name), reverse=True,
)
for archive in archives[keep:]:
	archive.unlink()
PY
}

# systemd's active state precedes application readiness during cold startup.
verify_http() {
	local label="$1" url="$2" code=000 attempt
	for attempt in $(seq 1 12); do
		code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url") || code=000
		if [[ "$code" == 200 ]]; then
			printf '  %-40s %s\n' "$label" "$code"
			return 0
		fi
		[[ "$attempt" == 12 ]] || sleep 5
	done
	printf '  %-40s %s\n' "$label" "$code"
	return 1
}
