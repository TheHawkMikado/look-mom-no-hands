# Paperclip for No Hands

Paperclip is the team behind the assistant: agents with roles, budgets and
an audit trail. No Hands talks to it; you never have to open its board.

One command, once:

```sh
./Scripts/paperclip/setup.sh
```

It installs Node if needed, asks for your Anthropic key (Enter to skip),
starts Paperclip on this machine, creates the "No Hands" company and starter
agents, opens the sign-in page so you can paste the account token, and sets
Paperclip and the bridge to start at login. Rerun it any time; it only does
what is still missing.

**Already hosting Paperclip (Railway, a VPS)?** Use that instead; nothing
then has to run on your machine and delegation works while your Mac sleeps:

```sh
./Scripts/paperclip/setup.sh --railway https://your-paperclip.up.railway.app
```

It signs you in to that Paperclip (browser approval), mints a board API key,
hires the two starter agents there as Claude Code agents (Paperclip's image
ships the CLI; set `ANTHROPIC_API_KEY` in the Railway service's variables or
paste it when asked), and registers the connection in direct mode. Pass
`--key …` if you already have a board API key.

The pieces it runs, if you'd rather drive them yourself:

```sh
./Scripts/paperclip/up.sh                 # start Paperclip on this machine (Node 20+; or PAPERCLIP_ENGINE=docker)
node Scripts/paperclip/bootstrap.mjs      # create the "No Hands" company + starter agents
NOHANDS_APP_TOKEN=… node Scripts/paperclip/bootstrap.mjs   # connect it to your account
node Scripts/paperclip/bridge.mjs         # keep this running (Paperclip is on localhost)
./Scripts/paperclip/install-launchagents.sh    # starts at login, restarts if it stops; --uninstall to remove
```

Get the token by opening `https://nohandsapp.com/app/login?client=bridge`
after signing in. A real `ANTHROPIC_API_KEY` in `Scripts/paperclip/.env`
makes the Content Drafter write real drafts (stubs otherwise).

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
