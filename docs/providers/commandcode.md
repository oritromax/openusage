# Command Code

Tracks [Command Code](https://commandcode.ai) plan credits and usage limits — the same numbers the
CLI's `/usage` screen shows.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Plan credits used this billing period, in dollars, against your plan's monthly allowance plus any purchased or free credits. Resets at renewal. |
| 5-Hour | Rolling 5-hour usage limit (percentage of the cap) |
| Weekly | Weekly usage limit (percentage of the cap) |
| Requests | Requests made this billing period |
| Spend This Period | Dollars spent this billing period |
| Org Spend Limit | Your org's org-wide spend limit, when it has one (off by default) |

Your plan name (Go, GOAT, Pro, Max, Ultra, Teams Pro…) shows beside the provider name.

## Where credentials come from

You don't need the CLI — an API key works on its own. OpenUsage uses the first key it finds:

1. A key you saved in **Settings → API Keys** (stored in `~/.config/openusage/commandcode.json`)
2. The `COMMAND_CODE_API_KEY` environment variable
3. The Command Code CLI's login (`~/.commandcode/auth.json`)

2 and 3 follow the CLI's own order, so OpenUsage shows the same account the CLI uses. If you're
logged in to the CLI there's nothing to set up. Settings shows that key as **From Command Code CLI**,
and you can override it with a different key. Clearing a key in Settings only removes OpenUsage's
copy. It never logs the CLI out.

## Setup

- **CLI users:** run `cmd login` once. Command Code turns on automatically.
- **API-only users:** create an API key in your Command Code settings, then add it in
  **Settings → API Keys**, or export it:

```bash
export COMMAND_CODE_API_KEY="YOUR_API_KEY"
```

## Under the hood

OpenUsage calls the same endpoints as the CLI's `/usage` screen, on `https://api.commandcode.ai` with
your key as a Bearer token:

- `GET /alpha/whoami?limits=1` — which org the key belongs to, plus org spend limits.
- `GET /alpha/billing/credits` — credits left (monthly, purchased, free) and the 5-hour/weekly limits.
- `GET /alpha/billing/subscriptions` — plan, status, and billing period.
- `GET /alpha/usage/summary` — spend and request count since the billing period started.

The credits pool matches the CLI: an active plan's monthly allowance plus purchased and free credits.
Without an active plan, it's this period's spend plus what's left. These are undocumented `/alpha/`
endpoints, so Command Code may change them without notice.

## Troubleshooting

- **"No Command Code API key"** — run `cmd login`, or add a key in Settings → API Keys.
- **"Command Code API key invalid or expired"** — the key was rejected (401/403). Log in again with
  `cmd login`, or replace the saved key.
- **Some rows show "No data"** — the billing data came back, but without that number (for example, no
  5-hour limit on your plan, or the usage summary request failed). The other rows still update.
