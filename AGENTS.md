# Brim for agents

How to read limits and switch accounts for a user with the `brim` command. Brim must be installed on the Mac you run on (`brim` on `PATH`, or `/Applications/Brim.app/Contents/MacOS/brim`).

## Read

```sh
brim status --json         # usage per account; add --fresh to fetch now
brim where --json          # which account each tool holds, and the logins parked in ~/.brim/vault.json
brim list                  # accounts and the tools holding each
```

`<account>` in every command is a label, an email, or an id prefix from `brim list`.

## Switch a tool

```sh
brim switch <account> claude-code|codex|hermes|omp --no-open
```

- If Brim already has a login for that account and tool, the switch is instant and prints `<Tool> → <label>`.
- Otherwise Brim prints `Open this to sign <Tool> in as <label>:` and a sign-in link, then waits for the sign-in. Without `--no-open` Brim opens the link in the user's default browser instead.
- Exit code 0 means switched. Anything else prints `brim: switching <Tool> to <label> failed: <reason>` on stderr and leaves the tool as it was.

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

## Add an account

```sh
brim add claude|codex --no-open [--label NAME]
brim add openrouter --env OPENROUTER_API_KEY [--label NAME]
```

The sign-in works the same as for a switch.

## Don't

- Copy tokens between tools or files. Refresh tokens rotate: a second copy dies, or logs out the tool that had it, as soon as either copy is used.
- Edit `~/.brim/vault.json`, `~/.brim/accounts.json`, or a tool's credential store by hand. `brim switch` backs up each store and writes it atomically.
- Run `codex login` while a ChatGPT sign-in is open: both need port 1455, and Brim fails with `port 1455 is busy`.
