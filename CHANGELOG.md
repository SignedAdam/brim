# Changelog

## 0.5.0

- `brim log`: what Brim did and what went wrong, from the app and the command line: switches (with the account the tool had before), failed switches and sign-ins, accounts added, renamed, hidden or removed, token refreshes, usage fetch errors and recoveries, parked logins that can't be refreshed, resets used, and alerts. Filter with `--kind`, `--kind error`, `--account` and `--since`; `-f` keeps printing new events. It's `~/.brim/events.jsonl` and replaces the free-text `brim.log`.
- `brim switch <account> <tool> <tool>…` switches several tools at once, `all` switches every tool on this Mac that takes the account, and `--json` prints a result per tool.
- `brim reset <account>` uses a banked limit reset from the command line. It asks first; `--yes` skips the question.
- Claude accounts show and use their banked limit resets too, in the notch ("2 resets", hold to use one) and with `brim reset`. The tooltip and `brim status --json` (`next_reset`) name the reset that goes next and the limits it clears, since a Claude reset can clear the Week and Fable limits or Fable alone.
- `brim hide` and `brim show` do what the account checkbox in Settings does. `brim list --json` lists accounts with the tools holding each and the parked logins that make a switch instant. `brim status <account>…` shows just those accounts.
- A label shared by a Claude and a ChatGPT account names both: `brim status adam` shows both, `brim switch adam all` signs each tool in as the one it takes. Where one account is needed, Brim asks for the id prefix instead of picking one.
- Claude rows show the Fable weekly limit where the 5-hour session used to be. A Claude account that still has a 5-hour session shows it under its name, as "Session 42%". The column header names what each row shows, such as "Fable / Session" with Claude and ChatGPT accounts.

## 0.4.0

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
