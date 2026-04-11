# Script Overview

The `scripts/` directory automates EC2 runtime bring-up, shutdown, Route53 updates, and backend deployment handoff for [Market data notification](https://github.com/hanchiang/market-data-notification).

Run these scripts from `instances/scripts/`.

## `start.sh`
- Starts the EC2 instance if needed
- Waits for the instance to be running
- Updates the Route53 record for the service domain
- Calls `../ansible/start.sh` to reconcile host configuration
  - nginx and certbot TLS setup
  - feature-branch Let's Encrypt backup reconciliation after TLS setup
- Resolves the latest successful backend CI build on `master`
- Dispatches the backend deploy workflow using that image SHA

Inputs:

```bash
./start.sh <github token> <ssh user> <path to ssh private key>
```

## `stop.sh`
- Removes the Route53 record
- Stops the EC2 instance

```bash
./stop.sh
```
