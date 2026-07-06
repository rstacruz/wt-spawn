# wt-spawn

Create git worktrees and delegate tasks to AI agents.

## Installation

- Install [worktrunk](https://github.com/max-sixty/worktrunk).
- Copy [`wt-spawn`](./wt-spawn) to a bin directory (eg, ~/.local/bin).

## Usage

Use wt-spawn to start a new piece of work. Pass a prompt with a supported [agent](#agents) (eg, `#sonnet` is Claude Code with Sonnet).

```sh
wt-spawn "#sonnet implement the plan in ~/.plans/refactor-auth.md"

# or:
wt-spawn                           # open text editor
wt-spawn @prompt.txt               # via file
echo "add dark mode" | wt-spawn -  # via stdin
```

This will:

- Come up with a branch name [automatically](#auto-branch-naming)
- Create a branch and worktree via *worktrunk*
- Create an empty draft PR
- Spawn Claude Code with the Sonnet model in your multiplexer (eg, cmux, Herdr, Zellij, Tmux)

## Practical use cases

One shotting trivial work. For simple changes, it should be as easy as possible to open a new PR.

```sh
wt-spawn "#sonnet fix test failure in path/to/my.test.ts"
wt-spawn "#sonnet change spelling from American to British English in src/components/Onboarding/"
```

Agentic orchestration. Ask your coding agent to use wt-spawn directly.

```
Read 'wt-spawn --help' for context.
Spawn 3 #opus agents for: create DB migration, update docs, and UI stub implementstion.
```

Implementing plans. Keep one Claude session for planning, then spin off implementation via wt-spawn.

```
/plan add rate limiting to /videos API
# ...many turns later...

approved. run wt-spawn "#sonnet #implement <plan file>"
```

## Multiplexers

wt-spawn automatically creates workspaces using the multiplexer being used. No configuration or parameters needed, it will auto-detect whatever may be running. Supported multiplexers:

- [Herdr](https://herdr.dev/)
- [cmux](https://github.com/craigsc/cmux)
- [Zellij](https://zellij.dev/) (0.44+)
- [iTerm2](https://iterm2.com/)
- [tmux](https://github.com/tmux/tmux)

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

Prompt templates are available via `-t/--template` or via hashtags.

```sh
wt-spawn "#plan fix issue XYZ-1234"
# Expands to the prompt:
#
#    Create a plan. Details: fix issue XYZ-1234
#
```

They can be configured. Here are the defaults:

```sh
# ~/.config/wt-spawn/config.sh
PROMPT_TEMPLATES[plan]='Create a plan. Details:'
PROMPT_TEMPLATES[implement]='/goal Implement this plan as described, ensure PR title and description are accurate and sensible. Ultrathink. Plan:'
```

Templates can also be invoked via `-t/--template`:

```sh
wt-spawn -t "plan" "fix issue XYZ-1234"
```

## Agents

Supports the following agents by default, and more can be added via custom configuration.

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Pi](https://github.com/earendil-works/pi-coding-agent)
- [Codex](https://github.com/openai/codex)
- [OpenCode](https://opencode.ai/)
- ...bring your own via config

Agents can be chosen using `-a/--agent <name>`.

```sh
wt-spawn -a "sonnet" "translate README.md to French, and save to README.fr.md"
```

Agents can be configured. Here are the defaults:

```sh
# ~/.config/wt-spawn/config.sh
AGENTS[claude]='claude --dangerously-skip-permissions'
AGENTS[codex]='codex --sandbox workspace-write --ask-for-approval never'
AGENTS[fable]='claude --model fable --dangerously-skip-permissions'
AGENTS[gpt-5.4]='codex --sandbox workspace-write --ask-for-approval never --model gpt-5.4'
AGENTS[gpt-5.5]='codex --sandbox workspace-write --ask-for-approval never --model gpt-5.5'
AGENTS[haiku]='claude --model haiku --dangerously-skip-permissions'
AGENTS[opencode]='opencode --auto --prompt'
AGENTS[opus]='claude --model opus --dangerously-skip-permissions'
AGENTS[pi]='pi'
AGENTS[sonnet]='claude --model sonnet --dangerously-skip-permissions'
```

## Auto branch naming

Branch/workspace name inference runs through a small, cheap model call. Configure which CLI it uses:

```sh
INFER_HARNESS=claude   # "pi", "claude", or "opencode" (default: claude)
INFER_MODEL=           # empty = auto-pick per harness:
                       #   claude → haiku, pi → openai-codex/gpt-5.4-mini, opencode → opencode/big-pickle
```

## Branch name override

Use `--branch NAME` (or `-b`) to bypass LLM inference and set the branch name directly.
The workspace display name is derived automatically from the branch.

```sh
wt-spawn -a sonnet --branch feat/add-redis "add redis caching"
# branch = feat/add-redis, workspace name = Add redis
```

