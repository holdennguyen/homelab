# Nightly Shutdown/Startup

This page documents the automated nightly shutdown and startup of the OrbStack Kubernetes homelab cluster using macOS launchd.

## Overview

To save power and reduce wear on the host Mac mini M4, the homelab cluster automatically stops every night at 11:30 PM and restarts at 6:30 AM. This is implemented as host-level automation using macOS launchd, not as a Kubernetes resource.

**Note:** This is a temporary/quick solution. Future improvements may use more robust approaches.

### Implementation Decisions

- **Cluster status check**: Scripts use `kubectl get nodes` instead of `orb status k8s` because OrbStack 2.x does not support the latter. When the cluster is stopped, `kubectl` fails with connection refused.
- **Log path**: Logs are written to `~/Library/Logs/homelab/` (not `/var/log/homelab/`) because launchd runs as the logged-in user. User-level LaunchAgents cannot write to `/var/log` without elevated privileges.

## OrbStack CLI Reference

The OrbStack CLI provides commands to manage the Kubernetes cluster:

| Command | Purpose |
|---------|---------|
| `orb start k8s` | Start the Kubernetes cluster |
| `orb stop k8s` | Stop the Kubernetes cluster |
| `orb restart k8s` | Restart the cluster |
| `kubectl get nodes` | Check cluster status (used by scripts; `orb status k8s` not in OrbStack 2.x) |

These commands cleanly shut down and start the cluster without data loss. Running pods will be terminated gracefully, and PVCs (persistent volume claims) will be preserved and remounted on startup.

## Wrapper Scripts

Two wrapper scripts are provided in `scripts/` to add safety checks, logging, and health verification:

### `orb-stop.sh`

Stops the OrbStack Kubernetes cluster after checking state and logging.

- Checks if the cluster is running before attempting to stop
- Logs to `~/Library/Logs/homelab/shutdown.log`
- Verifies cluster has stopped after the command
- Idempotent: safe to run even if already stopped

### `orb-start.sh`

Starts the OrbStack Kubernetes cluster and waits for full health:

- Checks if the cluster is already running
- Starts the cluster with `orb start k8s`
- Waits up to 5 minutes for all nodes to become Ready
- Waits for critical system pods (kube-system, cert-manager, etc.) to be Running
- Triggers an ArgoCD hard refresh to re-sync all applications
- Waits up to 10 minutes for ArgoCD to report all apps Synced and Healthy
- Logs to `~/Library/Logs/homelab/startup.log`
- Includes summary of cluster state at the end

Both scripts use timestamped logging for observability.

## Launchd Configuration

Two launchd plist files are provided:

### `com.homelab.orbstop.plist`

Runs daily at **23:30** (11:30 PM).

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>23</integer>
    <key>Minute</key>
    <integer>30</integer>
</dict>
```

### `com.homelab.orbstart.plist`

Runs daily at **06:30** (6:30 AM).

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>6</integer>
    <key>Minute</key>
    <integer>30</integer>
</dict>
```

### Installation

On the Mac mini host:

```bash
# 1. Create the log directory
mkdir -p ~/Library/Logs/homelab

# 2. Copy the plist files to LaunchAgents (user-level, runs when user is logged in)
cp scripts/com.homelab.orbstop.plist ~/Library/LaunchAgents/
cp scripts/com.homelab.orbstart.plist ~/Library/LaunchAgents/

# 3. Load the jobs into launchd
launchctl load ~/Library/LaunchAgents/com.homelab.orbstop.plist
launchctl load ~/Library/LaunchAgents/com.homelab.orbstart.plist

# 4. Verify they are loaded
launchctl list | grep homelab

# 5. Test immediately (optional)
launchctl start com.homelab.orbstop   # test shutdown now
# (Wait for it to complete, then:)
launchctl start com.homelab.orbstart # test startup now
```

### Modifying Times

To change the schedule, edit the `<dict>` section in each plist:

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>23</integer>   <!-- Change hour (0-23) -->
    <key>Minute</key>
    <integer>30</integer>   <!-- Change minute (0-59) -->
</dict>
```

After editing, unload and reload the plist:

```bash
launchctl unload ~/Library/LaunchAgents/com.homelab.orbstop.plist
launchctl load ~/Library/LaunchAgents/com.homelab.orbstop.plist
```

### Disabling

To disable a job temporarily:

```bash
launchctl unload ~/Library/LaunchAgents/com.homelab.orbstop.plist
launchctl unload ~/Library/LaunchAgents/com.homelab.orbstart.plist
```

To re-enable, load them again.

To remove permanently, delete the plist files and unload them.

## Edge Cases & Behavior

### Mac Sleeping at Scheduled Time

Launchd's `StartCalendarInterval` triggers when the Mac wakes from sleep if the scheduled time was missed while asleep. The job will run shortly after wake.

**Note:** If the Mac is completely powered off at the scheduled time, the job will not run (launchd is not running). The next scheduled time will be the following day.

### Missed Jobs

- **Shutdown missed** (e.g., Mac was off at 23:30): The shutdown will simply not occur that night. The cluster will remain running overnight. The next night's shutdown at 23:30 will proceed normally.

- **Startup missed** (e.g., Mac was off at 06:30): The startup will not occur automatically. The cluster will remain stopped. You must start it manually with `orb start k8s` or wait until the next morning's scheduled startup.

### Idempotency

Both wrapper scripts check the current state before acting:

- **Stop script**: If the cluster is already stopped, it logs and exits successfully with no action.
- **Start script**: If the cluster is already running and healthy, it exits successfully with no action.

This means manual testing (running the scripts at any time) is safe.

### Logging

All logs are written to `~/Library/Logs/homelab/`:

- **Shutdown log**: `~/Library/Logs/homelab/shutdown.log`
- **Startup log**: `~/Library/Logs/homelab/startup.log`

Launchd captures stdout/stderr from the scripts and writes them to these files. The scripts output timestamped, leveled log lines to stdout.

**Log Rotation**: These logs are not automatically rotated. Monitor their size and manually truncate if needed:

```bash
> ~/Library/Logs/homelab/shutdown.log
```

### Observability

Check recent activity:

```bash
# View shutdown logs
tail -f ~/Library/Logs/homelab/shutdown.log

# View startup logs
tail -f ~/Library/Logs/homelab/startup.log

# Check if jobs are loaded
launchctl list | grep homelab

# Check last run timestamps
ls -la ~/Library/Logs/homelab/
```

## Testing Procedure

### 1. Manual Script Test

Run each script manually to verify they work:

```bash
# Stop test
./scripts/orb-stop.sh
# Check logs: cat ~/Library/Logs/homelab/shutdown.log
# Verify cluster stopped: kubectl get nodes (should fail with connection refused)

# Start test
./scripts/orb-start.sh
# Check logs: cat ~/Library/Logs/homelab/startup.log
# Verify cluster health:
#   kubectl get nodes (all Ready)
#   kubectl get pods --all-namespaces (check system pods Running)
#   kubectl get applications -n argocd (all Synced/Healthy)
```

### 2. Launchd Test

Test the launchd jobs without waiting for the scheduled time:

```bash
# Load if not already loaded
launchctl load ~/Library/LaunchAgents/com.homelab.orbstop.plist

# Trigger shutdown immediately
launchctl start com.homelab.orbstop

# Monitor the log
tail -f ~/Library/Logs/homelab/shutdown.log

# After it completes, test startup
launchctl start com.homelab.orbstart
tail -f ~/Library/Logs/homelab/startup.log
```

### 3. Full Cycle Validation

Perform an end-to-end test:

1. Ensure cluster is running and healthy (all pods Running, PVCs bound, ArgoCD synced)
2. Stop the cluster: `orb stop k8s` or run the shutdown script
3. Wait 5 minutes
4. Start the cluster: `orb start k8s` or run the startup script
5. Verify:
   - All pods reach Running state (including stateful sets)
   - All PVCs are Bound
   - ArgoCD applications become Synced and Healthy within ~10 minutes
   - Services are accessible (test a few endpoints if possible)

Document any issues found.

## Troubleshooting

### Job not running at scheduled time

- Verify the plist is loaded: `launchctl list | grep homelab`
- Check the system log for launchd errors: `log show --predicate 'process == "launchd"' --last 1h`
- Ensure the Mac was not asleep or powered off at the scheduled time
- Check that the script paths in the plist are correct and the scripts are executable

### Cluster fails to stop

- Check OrbStack status: `kubectl get nodes` (fails when cluster is stopped)
- Check for errors in shutdown log
- Manually stop: `orb stop k8s`
- If pods are stuck terminating, you may need to force delete them after timeout

### Cluster fails to start or health checks time out

- Check OrbStack status: `kubectl get nodes` (fails when cluster is stopped)
- Check startup log for specific failures
- Increase timeouts in `orb-start.sh` if needed (MAX_WAIT_CLUSTER_HEALTH, MAX_WAIT_ARGOCD)
- Check system resources: `top`, `df -h`
- Manually restart: `orb restart k8s`

### ArgoCD not syncing

- Check ArgoCD status: `kubectl get applications -n argocd`
- Manually trigger refresh: `kubectl patch application <app> -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`
- Check ArgoCD logs: `kubectl logs -n argocd deploy/argocd-server`
- Verify repo connectivity and credentials

### Log directory missing

Logs are written to `~/Library/Logs/homelab/`. Create it before first use:

```bash
mkdir -p ~/Library/Logs/homelab
```

## Rollback

To revert this automation:

1. Unload the launchd jobs:
   ```bash
   launchctl unload ~/Library/LaunchAgents/com.homelab.orbstop.plist
   launchctl unload ~/Library/LaunchAgents/com.homelab.orbstart.plist
   ```
2. Delete the plist files from `~/Library/LaunchAgents/`
3. (Optional) Delete the scripts from `scripts/` if they are no longer needed
4. (Optional) Delete the logs: `rm -rf ~/Library/Logs/homelab`

The OrbStack cluster will remain running continuously after rollback. To stop it manually, use `orb stop k8s`.

## Future Improvements

This implementation is intentionally simple. For a more robust solution, consider:

- Moving scripts to `/usr/local/bin/` or `/opt/homelab/bin/` for system-wide access
- Using a dedicated log rotation mechanism (`newsyslog` or `logrotate`)
- Adding health checks with alerts (e.g., send notification if cluster fails to start)
- Integrating with ArgoCD to ensure critical applications are healthy before marking success
- Adding PowerShell/Salted for remote management and monitoring
- Using a configuration file for times and thresholds instead of hardcoded values
- Switching to `launchd` system-level daemons (`/Library/LaunchDaemons/`) to run even when no user is logged in (requires root)
