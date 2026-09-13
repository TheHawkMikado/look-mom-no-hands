# Paperclip for No Hands

Paperclip is the team behind the assistant: agents with roles, budgets and
an audit trail. No Hands talks to it; you never have to open its board.

Three commands, once:

```sh
./Scripts/paperclip/up.sh                 # start Paperclip on this machine (Node 20+; or PAPERCLIP_ENGINE=docker)
node Scripts/paperclip/bootstrap.mjs      # create the "No Hands" company + starter agents
NOHANDS_APP_TOKEN=… node Scripts/paperclip/bootstrap.mjs   # connect it to your account
node Scripts/paperclip/bridge.mjs         # keep this running (Paperclip is on localhost)
```

Get the token by opening `https://nohandsapp.com/app/login?client=bridge`
after signing in. Put a real `ANTHROPIC_API_KEY` in `Scripts/paperclip/.env`
so the Content Drafter writes real drafts (stubs otherwise).

## Two ways to connect

| | bridge (default) | direct |
|---|---|---|
| Paperclip lives | on your Mac/PC (localhost) | on a VPS the web service can reach |
| What runs | `bridge.mjs` next to Paperclip | nothing extra; the web service calls Paperclip |
| Works while the Mac sleeps | no | yes |
| Switch | `bootstrap.mjs` | `bootstrap.mjs --direct --paperclip https://…` |

Delete the connection any time (the app's settings, or
`DELETE /api/app/paperclip/connection`). Delegation stops; nothing else changes.

## What the starter agents do

`agents/drafter.mjs` is the whole contract: find my issues → check out →
do the work → post it as a comment → set the issue to in_review. No Hands
watches for that comment, asks you to approve from the phone, and closes the
issue out. Agents never publish, send or spend; the owner approves that step.

Hire more agents in Paperclip however you like (Claude Code, Codex, Cursor,
any adapter). No Hands matches tasks to agents by name, title and
capabilities, so give them a clear title.
