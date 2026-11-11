# Changelog

## Unreleased

- Signing a ChatGPT account in from the browser gets one login for Codex and one for OMP in the same tab, so later switches to that account never open the browser. OpenAI asks for a Continue click for the second login, or for the password or email code again when the browser isn't signed in to ChatGPT as that account.
- Hermes takes Claude accounts only.
- `brim switch <account> <tool> --no-open` prints the sign-in link instead of opening the browser.
- AGENTS.md: how an agent reads limits, switches tools and finishes a sign-in for the user.

## 0.3.0

- `brim add claude|codex --no-open` prints the sign-in link instead of opening the browser, so an agent or another browser can finish the sign-in.
- Switching a tool to an account you signed in to with `brim add` hands that login to the tool instead of opening the browser again.
- With more than 6 accounts the closed notch shows Claude and Codex side by side in two columns (on by default), and can leave out used-up accounts (off by default). Both are under Closed notch in Settings.
- Settings lists every account with a checkbox: unchecked hides it from the notch until you check it again. The Restore menu is gone.
- Plans use their current names. Claude: Max 20x is Ultra, Max 5x is Max. ChatGPT: Pro 100, Pro 200 and the new Pro 500 (Pro Max), and Business, Business Premium, Enterprise and Edu tiers as Codex names them.

## 0.2.0

- Use a banked ChatGPT limit reset from the notch: hover "N resets" and it asks "Reset?", press and hold to use one, let go early to cancel. The row shows the fresh limits straight away.

## 0.1.0

First release. Brim.app: Claude, ChatGPT / Codex and OpenRouter usage around the MacBook notch, account switching for Claude Code, Codex, Hermes Agent and OMP, alerts and hooks, `brim status --json`.
