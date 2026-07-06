#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR"

# --- Call log ---
CALL_LOG=$(mktemp "${TMPDIR:-/tmp}/wt-test-log-XXXXXX")

log_call() { echo "$*" >> "$CALL_LOG"; }

# --- Default mocks (minimal: log + succeed) ---

wt()     { log_call "wt" "$@"; }
pi()     { log_call "pi" "$@"; }
claude() { log_call "claude" "$@"; }
git()    { log_call "git" "$@"; }
gh()     { log_call "gh" "$@"; }
herdr()  { log_call "herdr" "$@"; }
cmux()   { log_call "cmux" "$@"; }
zellij() { log_call "zellij" "$@"; }
jq()     { command jq "$@"; }

# --- Source the code under test ---
WT_SPAWN_NO_CONFIG=1 source "$SCRIPT_DIR/../wt-spawn"
set +e  # wt-spawn enables errexit; shunit2 needs it off for fail()

# --- Helpers ---

assert_called() {
  local pattern="$1" msg="${2:-expected call matching '$1'}"
  grep -qF -- "$pattern" "$CALL_LOG" || fail "$msg
log:
$(cat "$CALL_LOG")"
}

assert_not_called() {
  local pattern="$1" msg="${2:-unexpected call matching '$1'}"
  if grep -qF -- "$pattern" "$CALL_LOG"; then
    fail "$msg
log:
$(cat "$CALL_LOG")"
  fi
}

assert_call_count() {
  local pattern="$1" expected="$2" msg="${3:-expected $expected calls matching '$1'}"
  local actual
  actual=$(grep -cF -- "$pattern" "$CALL_LOG" || true)
  if [[ "$actual" -ne "$expected" ]]; then
    fail "$msg (got $actual)
log:
$(cat "$CALL_LOG")"
  fi
}

# --- Tests ---

setUp() {
  : > "$CALL_LOG"
  FAKE_WT=$(mktemp -d)

  # Simulate herdr environment
  export HERDR_ENV=1
  export HERDR_WORKSPACE_ID="ws-test-123"
  unset CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT
  unset ZELLIJ TMUX

  AUTO_CREATE_DRAFT_PR=0
  INFER_HARNESS=claude
  INFER_MODEL=""
}

tearDown() {
  rm -rf "$FAKE_WT"
  rm -f "$CALL_LOG" "${PI_COUNT_FILE:-}" "${PI_RETRY_FILE:-}"
  unset XDG_CONFIG_HOME
}

test_main_herdr_integration() {
  INFER_HARNESS=pi

  # Scenario-specific overrides
  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/test-feature", "name": "Test Feature"}'
  }

  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "add test feature"

  # Single pi call → worktree → workspace name → herdr dispatch
  assert_call_count "pi " 1 "exactly one pi call"
  assert_called "pi" "pi called for branch/name inference"
  assert_called "wt switch" "wt switch called"
  assert_called "--create feat/test-feature" "correct branch"
  assert_called "herdr workspace create" "herdr workspace create"
  assert_called "--label Test Feature" "correct workspace label"
  assert_called "herdr pane run" "herdr pane run"

  # No PR commands
  assert_not_called "gh pr create"
  assert_not_called "git commit"
}

test_retry_on_first_failure() {
  INFER_HARNESS=pi
  PI_RETRY_FILE=$(mktemp "${TMPDIR:-/tmp}/wt-pi-retry-XXXXXX")
  echo 0 > "$PI_RETRY_FILE"
  pi() {
    log_call "pi" "$@"
    local n; n=$(cat "$PI_RETRY_FILE" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$PI_RETRY_FILE" 2>/dev/null || true
    case $n in
      0) echo 'not json at all just junk' ;;
      1) echo '{"branch": "feat/retry-works", "name": "Retry Works"}' ;;
    esac
  }
  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "add retry test"

  assert_call_count "pi " 2 "exactly two pi calls (retry)"
  assert_called "feat/retry-works" "branch from retry"
  assert_called "--label Retry Works" "workspace label from retry"
  rm -f "$PI_RETRY_FILE"
}

test_strips_markdown_fenced_json() {
  INFER_HARNESS=pi
  pi() {
    log_call "pi" "$@"
    printf '```json\n{"branch": "feat/fenced-json", "name": "Fenced Json"}\n```\n'
  }
  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "add fenced json test"

  assert_call_count "pi " 1 "single pi call, no retry needed"
  assert_called "feat/fenced-json" "branch parsed despite code fence"
  assert_called "--label Fenced Json" "workspace label parsed despite code fence"
}

test_print_default_config() {
  local output
  output=$(print_default_config)

  # Output must be valid shell syntax
  echo "$output" | bash -n 2>/dev/null || fail "print_default_config output is not valid shell"

  # Must contain expected keys
  grep -q '^INFER_HARNESS=' <<<"$output" || fail "missing INFER_HARNESS"
  grep -q '^INFER_MODEL=' <<<"$output" || fail "missing INFER_MODEL"
  grep -q '^AGENTS\[pi\]=' <<<"$output" || fail "missing AGENTS[pi]"
  grep -q '^PROMPT_TEMPLATES\[plan\]=' <<<"$output" || fail "missing PROMPT_TEMPLATES[plan]"
  grep -q '^AUTO_CREATE_DRAFT_PR=' <<<"$output" || fail "missing AUTO_CREATE_DRAFT_PR"
  grep -q '^INITIAL_COMMIT_MESSAGE=' <<<"$output" || fail "missing INITIAL_COMMIT_MESSAGE"
  grep -q '^PR_REMOTE=' <<<"$output" || fail "missing PR_REMOTE"
}

test_init_creates_config() {
  local tmp_config_dir
  tmp_config_dir=$(mktemp -d)
  XDG_CONFIG_HOME="$tmp_config_dir"

  init_config

  local cfg="$tmp_config_dir/wt-spawn/config.sh"
  assertTrue "config file exists" "[[ -f $cfg ]]"
  assertTrue "config is valid shell" "bash -n $cfg"

  rm -rf "$tmp_config_dir"
}

test_print_default_config_round_trip() {
  # Set known values with single quotes to verify escaping round-trips.
  # Mutations run in a command-substitution subshell to avoid leaking
  # global state into later tests.
  local output
  output=$(
    INFER_MODEL="model'with'quotes"
    AGENTS[agent-has-quote]="flags'with'quotes"
    PROMPT_TEMPLATES[tmpl-has-quote]="template'with'quotes"
    INITIAL_COMMIT_MESSAGE="msg'with'quotes"
    print_default_config
  )

  # Source the emitted config in a subshell and verify round-trip
  (
    unset INFER_MODEL AGENTS PROMPT_TEMPLATES INITIAL_COMMIT_MESSAGE
    declare -A AGENTS PROMPT_TEMPLATES
    eval "$output"
    [[ "$INFER_MODEL" == "model'with'quotes" ]] || exit 1
    [[ "${AGENTS[agent-has-quote]}" == "flags'with'quotes" ]] || exit 1
    [[ "${PROMPT_TEMPLATES[tmpl-has-quote]}" == "template'with'quotes" ]] || exit 1
    [[ "$INITIAL_COMMIT_MESSAGE" == "msg'with'quotes" ]] || exit 1
  ) || fail "round-trip failed: single-quote values not preserved"
}

test_init_refuses_existing() {
  local tmp_config_dir
  tmp_config_dir=$(mktemp -d)
  mkdir -p "$tmp_config_dir/wt-spawn"
  touch "$tmp_config_dir/wt-spawn/config.sh"
  XDG_CONFIG_HOME="$tmp_config_dir"

  local output status
  output=$(init_config 2>&1) && status=$? || status=$?

  assertEquals "init_config exits non-zero when config exists" 1 "$status"
  echo "$output" | grep -qi 'already exists' || fail "error message should mention file exists"

  rm -rf "$tmp_config_dir"
}

test_non_prefixed_branch_accepted() {
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "add-redis-caching", "name": "Add Redis caching"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "add redis caching"

  assert_called "--create add-redis-caching" "non-prefixed branch accepted"
  assert_call_count "pi " 1 "exactly one pi call for valid output"
}

test_print_default_config_new_agents() {
  local output
  output=$(print_default_config)

  # New agents present
  grep -Fq "AGENTS[codex]=" <<<"$output" || fail "missing AGENTS[codex]"
  grep -Fq "AGENTS[gpt-5.4]=" <<<"$output" || fail "missing AGENTS[gpt-5.4]"
  grep -Fq "AGENTS[gpt-5.5]=" <<<"$output" || fail "missing AGENTS[gpt-5.5]"
  grep -Fq "AGENTS[opencode]=" <<<"$output" || fail "missing AGENTS[opencode]"

  # Old agents absent
  ! grep -Fq "AGENTS[pi-deepseek]=" <<<"$output" || fail "unexpected AGENTS[pi-deepseek]"
  ! grep -Fq "AGENTS[pi-gpt54]=" <<<"$output" || fail "unexpected AGENTS[pi-gpt54]"
}

test_print_default_config_quickimplement_absent() {
  local output
  output=$(print_default_config)

  ! grep -Fq "PROMPT_TEMPLATES[quickimplement]=" <<<"$output" || fail "unexpected PROMPT_TEMPLATES[quickimplement]"
  grep -Fq "PROMPT_TEMPLATES[plan]=" <<<"$output" || fail "missing PROMPT_TEMPLATES[plan]"
  grep -Fq "PROMPT_TEMPLATES[implement]=" <<<"$output" || fail "missing PROMPT_TEMPLATES[implement]"
}

# --- Hashtag tests ---
# These use the direct-exec launch branch (not herdr) so the description
# reaches CALL_LOG unescaped, and run `main` in a subshell: it does a real
# `cd` into $FAKE_WT and, on error, `exit`s the sourced script's process.
# The default harness (claude) also does the branch/name inference call, so
# the same claude() mock must echo valid JSON on every invocation.

test_hashtag_agent_resolves() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr "#sonnet fix bug"
  )
  assert_called "claude --model sonnet" "sonnet agent invoked"
  assert_called "fix bug" "prompt with tag stripped"
}

test_hashtag_template_resolves() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr -a sonnet "#plan fix bug"
  )
  assert_called "Create a plan. Details:" "template text prepended"
  assert_called "fix bug" "body kept"
}

test_hashtag_agent_and_template() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr "#plan #sonnet fix bug"
  )
  assert_called "claude --model sonnet" "sonnet agent invoked"
  assert_called "Create a plan. Details:" "template text prepended"
}

test_hashtag_midtext_untouched() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr "#sonnet fix issue #1234"
  )
  assert_called "fix issue #1234" "mid-text hashtag left literal"
}

test_hashtag_multiline_prompt_body() {
  # bash's [[ =~ ]] does not set REG_NEWLINE, so `.` in parse_hashtags'
  # regex matches newlines too — a multi-line @file/$EDITOR/stdin body
  # must parse the same as a single-line one.
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr -a sonnet $'#plan\nfix bug across multiple\nlines of detail'
  )
  assert_called "Create a plan. Details:" "template resolved despite newline after tag"
  assert_called "fix bug across multiple" "multi-line body preserved"
}

test_hashtag_lone_template_empty_body() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/plan-only", "name": "Plan only"}'; }
    main --no-create-pr -a sonnet "#plan"
  )
  assert_called "Create a plan. Details:" "template text alone is not an empty prompt"
}

test_hashtag_lone_agent_empty_body_errors() {
  local status=0
  ( main --no-create-pr "#sonnet" ) || status=$?
  assertEquals "agent tag alone has no body to fall back on" 1 "$status"
}

test_hashtag_flag_wins() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr -a opus "#sonnet fix bug"
  )
  assert_called "claude --model opus" "explicit -a flag wins over #tag"
  assert_not_called "--model sonnet" "hashtag agent not used"
  assert_called "fix bug" "hashtag still stripped from prompt text"
}

test_no_agent_no_hashtag_errors() {
  local status=0
  ( main --no-create-pr "fix bug" ) || status=$?
  assertEquals "agent required when absent from flag and prompt" 2 "$status"
}

test_hashtag_via_file() {
  local promptfile
  promptfile=$(mktemp "${TMPDIR:-/tmp}/wt-prompt-XXXXXX")
  printf '#sonnet fix bug via file' > "$promptfile"
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr "@$promptfile"
  )
  assert_called "claude --model sonnet" "sonnet resolved from @file prompt"
  assert_called "fix bug via file" "tag stripped from @file prompt"
  rm -f "$promptfile"
}

test_hashtag_via_stdin() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-create-pr - <<< "#sonnet fix bug via stdin"
  )
  assert_called "claude --model sonnet" "sonnet resolved from stdin prompt"
  assert_called "fix bug via stdin" "tag stripped from stdin prompt"
}

test_default_harness_is_claude() {
  # INFER_HARNESS left at setUp's default ("claude")
  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  claude() {
    log_call "claude" "$@"
    echo '{"branch": "feat/claude-default", "name": "Claude default"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "use claude by default"

  assert_called "claude" "claude called for branch/name inference by default"
  assert_called "--model haiku" "auto-picked haiku model"
  assert_not_called "pi " "pi not called when harness is claude"
}

test_infer_harness_pi() {
  INFER_HARNESS=pi
  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/pi-harness", "name": "Pi harness"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "use pi explicitly"

  assert_called "pi " "pi called when INFER_HARNESS=pi"
  assert_not_called "claude " "claude not called when harness is pi"
}

test_resolve_infer_model_defaults() {
  INFER_HARNESS=claude
  INFER_MODEL=""
  assertEquals "haiku" "$(resolve_infer_model)"

  INFER_HARNESS=pi
  INFER_MODEL=""
  assertEquals "openai-codex/gpt-5.4-mini" "$(resolve_infer_model)"

  INFER_HARNESS=claude
  INFER_MODEL="custom-model"
  assertEquals "custom-model" "$(resolve_infer_model)"

  INFER_HARNESS=pi
  INFER_MODEL="custom-model"
  assertEquals "custom-model" "$(resolve_infer_model)"
}

test_resolve_infer_model_invalid_harness() {
  INFER_HARNESS=bogus
  INFER_MODEL=""

  local output status
  output=$(resolve_infer_model 2>&1) && status=$? || status=$?
  assertEquals "resolve_infer_model fails on unknown harness" 1 "$status"
  echo "$output" | grep -qi 'unknown INFER_HARNESS' || fail "error message should mention unknown INFER_HARNESS"
}

test_resolve_infer_model_invalid_harness_even_with_model_set() {
  # INFER_MODEL being set must not skip harness validation
  INFER_HARNESS=bogus
  INFER_MODEL="some-model"

  local output status
  output=$(resolve_infer_model 2>&1) && status=$? || status=$?
  assertEquals "resolve_infer_model fails on unknown harness even with INFER_MODEL set" 1 "$status"
  echo "$output" | grep -qi 'unknown INFER_HARNESS' || fail "error message should mention unknown INFER_HARNESS"
}

test_ensure_valid_infer_harness() {
  INFER_HARNESS=pi
  assertTrue "pi is valid" "ensure_valid_infer_harness"

  INFER_HARNESS=claude
  assertTrue "claude is valid" "ensure_valid_infer_harness"

  INFER_HARNESS=bogus
  local output status
  output=$(ensure_valid_infer_harness 2>&1) && status=$? || status=$?
  assertEquals "bogus harness is invalid" 1 "$status"
  echo "$output" | grep -qi 'unknown INFER_HARNESS' || fail "error message should mention unknown INFER_HARNESS"
}

test_ensure_valid_infer_harness_missing_binary() {
  INFER_HARNESS=claude

  # Run in a subshell with an empty PATH and the mock function unset, so
  # neither a real `claude` binary nor the test mock can be found —
  # regardless of what's actually installed on the machine running the tests.
  local output status
  output=$(unset -f claude; PATH=""; ensure_valid_infer_harness 2>&1) && status=$? || status=$?
  assertEquals "missing claude binary is invalid" 1 "$status"
  echo "$output" | grep -qi 'not installed' || fail "error message should mention not installed"
}

test_get_muxer_type_zellij() {
  # Simulate zellij environment: ZELLIJ set, no cmux/herdr
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT TMUX
  export ZELLIJ=1
  assertEquals "zellij" "$(get_muxer_type)"
  unset ZELLIJ
}

test_zellij_integration() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT TMUX
  export ZELLIJ=1
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/zellij-test", "name": "Zellij Test"}'
  }

  zellij() {
    log_call "zellij" "$@"
  }

  main --no-create-pr -a sonnet "zellij integration"

  assert_called "zellij action new-tab" "zellij new-tab called"
  assert_called "--cwd $FAKE_WT" "zellij tab with correct cwd"
  assert_called "--name Zellij Test" "zellij tab with correct name"
  assert_called "--close-on-exit" "zellij tab with close-on-exit"
  assert_called "bash -c bash" "zellij tab runs cmdfile"
  assert_not_called "herdr " "herdr not called"
  assert_not_called "cmux " "cmux not called"

  unset ZELLIJ
}

test_zellij_create_tab_muxer_display() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT TMUX
  export ZELLIJ=1
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/zellij-muxer", "name": "Zellij Muxer"}'
  }

  zellij() {
    log_call "zellij" "$@"
  }

  local output
  output=$(main --no-create-pr -a sonnet "zellij muxer display" 2>&1) || true

  echo "$output" | grep -qF 'muxer:    zellij' || fail "muxer displayed as zellij in output"

  unset ZELLIJ
}

test_invalid_infer_harness_fails_fast() {
  INFER_HARNESS=bogus

  local output status
  output=$(main --no-create-pr -a sonnet "should never run" 2>&1) && status=$? || status=$?

  assertEquals "main exits non-zero on invalid INFER_HARNESS" 2 "$status"
  echo "$output" | grep -qi 'unknown INFER_HARNESS' || fail "error message should mention unknown INFER_HARNESS"
  assert_not_called "pi " "pi never called on invalid harness"
  assert_not_called "claude " "claude never called on invalid harness"
  assert_not_called "wt switch" "worktree never created on invalid harness"
}

test_positional_args_joined() {
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet fix bug

  assert_called "fix bug" "positional args joined into prompt"
  assert_call_count "pi " 1 "exactly one pi call"
}

test_positional_stdin() {
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/stdin-test", "name": "Stdin test"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet - <<< "fix via stdin"

  assert_called "feat/stdin-test" "stdin prompt read via -"
  assert_called "fix via stdin" "stdin content in prompt"
}

test_positional_file() {
  INFER_HARNESS=pi
  local promptfile
  promptfile=$(mktemp "${TMPDIR:-/tmp}/wt-prompt-XXXXXX")
  printf 'fix via file' > "$promptfile"

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/file-test", "name": "File test"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-create-pr -a sonnet "@$promptfile"

  assert_called "feat/file-test" "file prompt read via @file"
  assert_called "fix via file" "file content in prompt"
  rm -f "$promptfile"
}

test_help_omits_p_flag() {
  local output
  output=$(show_help)

  # OPTIONS section must not list -p/--prompt as a flag
  ! grep -q -- '-p, --prompt' <<<"$output" || fail "show_help must not list -p flag"
  # But an agent description like 'opencode --auto --prompt' may mention --prompt
  # legitimately — only the flag definition line should not exist.
}

# --- shunit2 bootstrap ---
# shellcheck disable=SC1091
source "$TEST_DIR/shunit2"
