# GitHub Actions deployment

`Deploy production` runs on pushes to `main` and manual dispatches of that branch. A manual run on another branch is skipped. Set `dry_run` to inspect the host without backing up, building, restarting, or recording a release. The workflow deploys the exact triggering SHA, including on reruns.

The workflow uses `deploy/deploy-sfn.sh` from the checked-out commit, with `SFN_REPO` pointing to its isolated Actions workspace. It does not deploy uncommitted files from the existing local app folder. Tests and builds remain enabled on real deployments. The existing hosted CI workflows continue independently; deployment uses the script's own test/build gates.

## Runner on this Mac

This repository has its own macOS ARM64 runner named `mamdani-sfn`, installed in `~/.local/share/github-actions/sfn` as user `julie`. Jobs require the labels `self-hosted`, `macOS`, `ARM64`, and `production-deploy`. GitHub runner v2.338.0 is installed as a user launchd service with `svc.sh`.

The Mac must stay awake and logged in. SSH uses the existing `~/julie.pem`, known hosts, and SSH configuration. RWYN uses the existing `cleon` alias and ARM64 Docker runtime; ferry and subways connect to `ubuntu@52.5.187.46`. Docker must be available for RWYN. Include `/opt/homebrew/bin` in the service PATH. Node 22 is provisioned into the Actions tool cache for ferry and subways; their dependencies come from `npm ci` and the committed lockfile.

Check the local service:

```sh
cd "$HOME/.local/share/github-actions/sfn"
./svc.sh status
```

GitHub **Settings → Actions → Runners** should show `mamdani-sfn` online. To temporarily pause this runner, run `./svc.sh stop`; resume with `./svc.sh start`. To uninstall it, stop it, run `./svc.sh uninstall`, and remove its registration under the repository's Runners settings. Existing local deploy shortcuts and SSH credentials are independent of the runner.

### Reinstalling the runner

Download the macOS ARM64 archive for [runner v2.338.0](https://github.com/actions/runner/releases/tag/v2.338.0). Verify its SHA-256 before extracting:

```text
df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2
```

Extract into a new empty runner directory, then register it using an expiring token generated with the existing authenticated GitHub CLI. Run these commands as `julie`, not root; do not print or persist the token:

```sh
export PATH="/opt/homebrew/bin:$PATH"
task_registration_token=$(gh api --method POST repos/jefuhr/subwayForNerds/actions/runners/registration-token --jq .token)
./config.sh --unattended --url https://github.com/jefuhr/subwayForNerds \
  --token "$task_registration_token" --name mamdani-sfn \
  --labels production-deploy --work _work
unset task_registration_token
./svc.sh install
./svc.sh start
```

Use a repository-specific runner registration and a separate runner directory for each app. No GitHub deployment secrets or inbound network rule changes are needed.

## Backups and failures

Backups stay private in `~/backups`, outside the Actions workspace; the script retains the newest five for this app after a successful deployment. They are not uploaded as Actions artifacts. The scripts print the backup path and recovery instructions. RWYN backups include credentials and a verified PostgreSQL dump; an image rollback requires compatibility with the current database schema.

Only one deployment per repository runs at a time, and a newer push does not cancel an active deployment. GitHub keeps one pending run per concurrency group, so intermediate pending pushes may be replaced by the newest. A failed test, build, backup, restart, or HTTP verification fails the job. `DEPLOYED_SHA` is written only after the script's success checks. Subways upstream feed failures remain warnings, as in the existing script.

## Verification

The deployment fixtures use temporary repositories and simulated SSH, npm, Docker (RWYN), and HTTP responses. They never contact production:

```sh
python3 test/deploy-script.test.py
bash -n deploy/deploy-sfn.sh
```

Before the first automatic deployment, run a dry run from a fresh production-branch checkout with `SFN_REPO` set to that checkout and `--branch` set to its full commit SHA. After publication, inspect the first deployment log, the public endpoints checked by the script, and the recorded `DEPLOYED_SHA`. Publishing this workflow to `main` immediately triggers a real deployment.

## Current production URLs and startup

The production URL is `https://subwaysfornerds.juliet.nyc`, with build and systemd `APP_BASE=/`. Override with `SFN_SITE` and `SFN_BASE` for another target. A mismatched build/server base fails before backup or sync. Required endpoints retry up to 12 times, five seconds apart.

Deployment backups contain release files and exclude `node_modules/` and `state/`. The 17 GB runtime feed state remains live and is not replaced by deployment or code rollback. These archives do not provide feed database recovery; manage state backups separately. The service stays running during backup.
