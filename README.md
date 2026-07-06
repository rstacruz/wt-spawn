# wt-spawn

Create git worktrees and delegate tasks to AI agents.

## Installation

- Install [worktrunk](https://github.com/max-sixty/worktrunk).
- Copy [`wt-spawn`](./wt-spawn) to a bin directory (eg, ~/.local/bin).

## Usage

Use wt-spawn to start a new piece of work. Pass a prompt with a supported [agent](#agents) (eg, `#sonnet` is Claude Code with Sonnet).

```sh
wt-spawn -p "#sonnet implement the plan in ~/.plans/refactor-auth.md"

# or: no arguments will open a text editor
wt-spawn
```

This will:

- Create a branch and worktree via *worktrunk*
- Create an empty draft PR
- Spawn Claude Code with the Sonnet model in your multiplexer (eg, cmux or Herdr)

## Multiplexers

wt-spawn automatically creates workspaces using the multiplexer being used. No configuration or parameters needed, it will auto-detect whatever may be running. Supported multiplexers:

- [Herdr](https://herdr.dev/)
- [cmux](https://github.com/craigsc/cmux)

## Configuration

Generate default config:

```sh
wt-spawn --init
```

Print defaults without writing:

```sh
wt-spawn --print-default-config
```

Config location: `${XDG_CONFIG_HOME:-~/.config}/wt-spawn/config.sh`

## Prompt template

Prompt templates are available via `-t/--template`.

```sh
wt-spawn -t "plan" -p "#plan fix issue #1234"
# Expands to the prompt:
#
#    Create a plan. Details: fix issue #1234
#
```

They can be configured. Here are the defaults:

```sh
# ~/.config/wt-spawn/config.sh
PROMPT_TEMPLATES[plan]='Create a plan. Details:'
PROMPT_TEMPLATES[implement]='/goal Implement this plan as described, ensure PR title and description are accurate and sensible. Ultrathink. Plan:'
```

Templates can also be loaded via hashtags:

```sh
wt-spawn -p "#plan fix issue #1234"
# same as: wt-spawn --template "plan" -p "fix issue #1234"
```

## Agents

Supports the following agents by default, and more can be added via custom configuration.

- Claude Code
- Pi
- Codex
- ...bring your own via config

Agents can be chosen using `-a/--agent <name>`.

```sh
wt-spawn -a "sonnet" -p "translate README.md to French, and save to README.fr.md"
```

Agents can be configured. Here are the defaults:

```sh
# ~/.config/wt-spawn/config.sh
AGENTS[pi]="pi"
AGENTS[claude]="claude --dangerously-skip-permissions"
AGENTS[sonnet]="claude --model sonnet --dangerously-skip-permissions"
AGENTS[haiku]="claude --model haiku --dangerously-skip-permissions"
AGENTS[opus]="claude --model opus --dangerously-skip-permissions"
AGENTS[fable]="claude --model fable --dangerously-skip-permissions"
AGENTS[codex]="codex --sandbox workspace-write --ask-for-approval never"
AGENTS[gpt-5.4]="codex --sandbox workspace-write --ask-for-approval never --model gpt-5.4"
AGENTS[gpt-5.5]="codex --sandbox workspace-write --ask-for-approval never --model gpt-5.5"
```

## Inference harness

Branch/workspace name inference runs through a small, cheap model call. Configure which CLI it uses:

```sh
INFER_HARNESS=claude   # or "pi" (default: claude)
INFER_MODEL=           # empty = auto-pick (haiku for claude, openai-codex/gpt-5.4-mini for pi)
```

