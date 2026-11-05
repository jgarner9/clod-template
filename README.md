# clod

Your Claude Code setup, in a repo of your own: the rules, skills, agents,
commands, settings and MCP servers you want on every machine. Keep it
private, since it's yours.

This is the starter. [bud](https://github.com/jgarner9/bud) makes your copy
from it: `bud install` (or `bud claude setup`) creates `<your GitHub
login>/clod`, private, from this template once you say yes, clones it into
`~/clod` and runs its `install.sh`. You can also do that by hand:

```sh
gh repo create clod --private --template jgarner9/clod-template --clone
cd clod && ./install.sh
```

## What goes where

| In this repo | Ends up in | How |
| --- | --- | --- |
| `claude/rules/*.md` | `~/.claude/rules/clod/` | Copied. Claude Code loads every rule there in every project |
| `claude/skills/<name>/SKILL.md` | `~/.claude/skills/<name>/` | Copied |
| `claude/agents/*.md` | `~/.claude/agents/` | Copied |
| `claude/commands/*.md` | `~/.claude/commands/` | Copied |
| `claude/settings.json` | `~/.claude/settings.json` | Merged in: objects key by key, lists joined, your other settings kept |
| `claude/mcp.json` | Claude Code's user-scope MCP servers | Added with `claude mcp add-json --scope user`; one you already have is left alone |

`$CLAUDE_CONFIG_DIR` replaces `~/.claude` when it's set. A file that's
already there and wasn't put there by clod is yours, so it's left alone (with
a warning).

## MCP servers

`claude/mcp.json` lists them by name, each the same JSON `claude mcp add-json`
takes:

```json
{
  "servers": {
    "context7": { "type": "http", "url": "https://mcp.context7.com/mcp" },
    "playwright": { "type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"] }
  }
}
```

Never commit a secret. Leave keys out of the JSON and set the server up to
read them from the environment, or add that one server by hand with
`claude mcp add`.

## Commands

`install.sh` links itself as `~/.local/bin/clod`, so after the first run:

```sh
clod apply        # install again after you change this repo (git pull first on other machines)
clod status       # what clod put here
clod uninstall    # take it out again; settings.json keeps what was merged in
```

`--dry-run` says what would change and changes nothing; `--yes` never asks.
It needs bash 3.2 or newer (macOS's own is fine) and `jq`.

`tests/run.sh` checks the installer against a throwaway home directory with a
fake `claude`; CI runs it with shellcheck.

## License

[MIT](LICENSE). Your copy is yours: keep the license or change it.
