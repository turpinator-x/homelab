# Claim watch

A read-only CronJob that reminds me on Telegram when DeFi rewards are ready to claim and when Flare staking needs a restake. App code: private repo `turpinator-x/defi-claim-watch` (AI-assisted, written with Claude Code). Manifests: `apps/base/claim-watch`, `apps/staging/claim-watch`.

## Why reminders and not a claim bot

Every claim function it watches pays only `msg.sender` (checked in verified contract source, 2026-11-12). Automating the claim would mean putting the wallet's private key on the cluster, so it doesn't: the job only reads public contract state and the P-chain validator list, and claims stay manual in MetaMask. The app repo has a test that fails if signing code ever appears.

## How it runs

- Every 15 minutes (`concurrencyPolicy: Forbid`, no retries: the next run is 15 minutes away).
- State (which reminders were sent) is a JSON file on a 64Mi `local-path` volume, so each reminder goes out once. Losing it only means one "Claim watch is running" summary message on the next run.
- Restricted Pod Security, non-root, read-only root filesystem, no service account token. NetworkPolicy: default deny, then DNS and HTTPS to public addresses only.
- If any check fails 3 runs in a row it sends one warning to Telegram, and one when it recovers.

## Secrets (owner steps)

`claim-watch-secret.yaml` holds the wallet address to watch, the Telegram bot token and the chat id, encrypted with SOPS (template: `claim-watch-secret.yaml.example`). The bot is a private one made for this job only (@BotFather), not the public Crypto Lighthouse channel bot.

`ghcr-pull-secret.yaml` is the same encrypted read:packages pull secret as `blockone-crypto-tax` (copied unchanged; Kustomize sets the namespace).

## Check it

```
kubectl --context homelab -n claim-watch get cronjob,jobs
kubectl --context homelab -n claim-watch logs job/<latest>
```

The last log line reads `checked at …: N active, N new, 0 errors, 0 failed sends`.
