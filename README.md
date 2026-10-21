# Brim

Your AI subscription limits, wrapped around the MacBook notch.

![Brim, open](docs/open.png)

Closed, it's a sliver either side of the camera: one hairline per account on the left, the next reset on the right.

![Brim, closed](docs/closed.png)

Hover the notch and it opens: every account's 5-hour session and weekly limit, how far through each window you are (the tick), and a countdown to each reset. On a screen without a notch it becomes a small pill in the menu bar.

- **Claude** and **ChatGPT / Codex**, as many accounts of each as you like. Your Claude Code and Codex CLI logins are picked up automatically; add others with a browser sign-in.
- **OpenRouter**: credit left and today's spend. A key in `$OPENROUTER_API_KEY` (or `~/.config/secrets/global.env`) is picked up by name, never copied; or add one with **Add OpenRouter Key…** / `brim add openrouter`.
- **Alerts** at thresholds you pick, when a balance runs low, when unused weekly quota is about to expire, when a limit resets, and when OpenAI or Anthropic announce a reset in public ([resets.albastov.com](https://resets.albastov.com)).
- **Agent-friendly**: `brim status --json`, plus hooks that get every alert as JSON, so an agent can spend leftover quota or pause heavy work.

## Install

macOS 14+, Xcode command line tools.

```sh
git clone https://github.com/SignedAdam/brim && cd brim
make install        # builds, links brim onto your PATH, runs at login
```

## Command line

```
brim status [--json] [--fresh]    usage per account
brim add claude|codex             sign in to another account
brim add openrouter [--env VAR]   add an OpenRouter key (stdin, or by env var name)
brim list | rename | remove       manage accounts
brim alerts                       recent alerts, JSON lines
brim quit
```

Everything lives in `~/.brim` (owner-only). Tokens from Claude Code and the Codex CLI are only read, never refreshed, so Brim never fights them over a login.
