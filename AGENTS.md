# Brim for agents

How to read limits and switch accounts for a user with the `brim` command. Brim must be installed on the Mac you run on (`brim` on `PATH`, or `/Applications/Brim.app/Contents/MacOS/brim`).

## Read

```sh
brim status --json [<account>…]   # usage per account, or just those; add --fresh to fetch now
brim where --json                 # which account each tool holds, and the logins parked in ~/.brim/vault.json
brim list --json                  # accounts, the tools holding each ("tools") and the parked logins that make a switch instant ("parked")
brim log --json [--kind error] [--since 1h] [--account <account>] [-f]
                                  # events, one JSON object per line: switches, sign-ins, token refreshes, fetch errors, resets, alerts
```

`<account>` in every command is a label, an email, or an id prefix from `brim list`. A label shared by a Claude and a ChatGPT account means both; where one account is needed and the name fits several, Brim exits 1 with `brim: <name> could be <id> (Claude) or <id> (Codex); name it by id prefix`.

Each event has `at`, `kind` (`app`, `switch`, `sign_in`, `account`, `refresh`, `fetch`, `vault`, `reset`, `alert`), `text`, `via` (`app` or `cli`), and when they apply `error` (set only on failures), `account` (id), `label`, `tool` and `from` (the account a switched tool had before).

## Switch a tool

```sh
brim switch <account> claude-code|codex|hermes|omp … --no-open [--json]
brim switch <account> all --no-open      # every tool on this Mac that takes the account
```

Tools switch one after another. `--json` prints an array with one `{"tool", "account", "label", "provider", "ok", "error"}` per tool; progress lines and sign-in links then go to stderr.

- If Brim already has a login for that account and tool, the switch is instant and prints `<Tool> → <label>`.
- Otherwise Brim prints `Open this to sign <Tool> in as <label>:` and a sign-in link, then waits for the sign-in. Without `--no-open` Brim opens the link in the user's default browser instead.
- Exit code 0 means every tool switched. Otherwise each failure prints `brim: switching <Tool> to <label> failed: <reason>` on stderr and leaves that tool as it was; the exit code is 1.

## Finish a sign-in

The link has to be opened in a browser **on the same Mac**: the provider sends the browser back to `http://localhost:<port>` (port 1455 for ChatGPT, a random port for Claude), where Brim is waiting. A browser on another machine can't finish it.

Signing in takes one of:

- the account's password,
- a one-time code sent to the account's email, which needs access to that mailbox,
- the Google, Apple or Microsoft account the user signs in with.

If none of those is available, hand the link to the user.

Then click **Continue** (ChatGPT) or **Authorize** (Claude). Brim checks the account: signing in as a different account fails with `the browser signed in as <email>, not <label>`.

### ChatGPT: one login per tool, in one tab

Codex and OMP each need their own ChatGPT login, because refresh tokens are single-use. When both need one, Brim's page reads `Login 1 of 2 saved` after the first sign-in and goes back to OpenAI after a second for the second login. The page then reads `Signed in. Brim saved 2 logins`.

- If the browser has an OpenAI session for the account, each extra login is one Continue click.
- If it doesn't, OpenAI asks for the password or an email code again.
- Brim waits up to 3 minutes per extra login. Stopping early keeps the logins already saved, and the switch still finishes.

## Use a banked reset

```sh
brim reset <account> --yes [--json]
```

Spends one of a ChatGPT account's banked limit resets (`reset_credits` in `brim status --json`): Session and Week go back to 0%. It can't be undone, so only run it when the user asks. Without `--yes` Brim asks on a terminal and refuses otherwise (exit 2). It prints the account's fresh usage, or says OpenAI hasn't caught up yet.

## Add an account

```sh
brim add claude|codex --no-open [--label NAME]
brim add openrouter --env OPENROUTER_API_KEY [--label NAME]
```

The sign-in works the same as for a switch.

## Don't

- Run `brim reset` because quota looks low. A reset is the user's to spend.

- Copy tokens between tools or files. Refresh tokens rotate: a second copy dies, or logs out the tool that had it, as soon as either copy is used.
- Edit `~/.brim/vault.json`, `~/.brim/accounts.json`, or a tool's credential store by hand. `brim switch` backs up each store and writes it atomically.
- Run `codex login` while a ChatGPT sign-in is open: both need port 1455, and Brim fails with `port 1455 is busy`.
