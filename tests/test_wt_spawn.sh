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
claude()  { log_call "claude" "$@"; }
opencode() { log_call "opencode" "$@"; }
git()    { log_call "git" "$@"; }
gh()     { log_call "gh" "$@"; }
herdr()  { log_call "herdr" "$@"; }
cmux()   { log_call "cmux" "$@"; }
zellij() { log_call "zellij" "$@"; }
tmux()   { log_call "tmux" "$@"; }
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
  INFER_HARNESS=auto
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

  main --no-pr -a sonnet "add test feature"

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

  main --no-pr -a sonnet "add retry test"

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

  main --no-pr -a sonnet "add fenced json test"

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
  grep -q "INFER_HARNESS='auto'" <<<"$output" || fail "INFER_HARNESS default should be auto"
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

  main --no-pr -a sonnet "add redis caching"

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
    main --no-pr "#sonnet fix bug"
  )
  assert_called "claude --model sonnet" "sonnet agent invoked"
  assert_called "fix bug" "prompt with tag stripped"
}

test_hashtag_template_resolves() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-pr -a sonnet "#plan fix bug"
  )
  assert_called "Create a plan. Details:" "template text prepended"
  assert_called "fix bug" "body kept"
}

test_hashtag_agent_and_template() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-pr "#plan #sonnet fix bug"
  )
  assert_called "claude --model sonnet" "sonnet agent invoked"
  assert_called "Create a plan. Details:" "template text prepended"
}

test_hashtag_midtext_untouched() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-pr "#sonnet fix issue #1234"
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
    main --no-pr -a sonnet $'#plan\nfix bug across multiple\nlines of detail'
  )
  assert_called "Create a plan. Details:" "template resolved despite newline after tag"
  assert_called "fix bug across multiple" "multi-line body preserved"
}

test_hashtag_lone_template_empty_body() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/plan-only", "name": "Plan only"}'; }
    main --no-pr -a sonnet "#plan"
  )
  assert_called "Create a plan. Details:" "template text alone is not an empty prompt"
}

test_hashtag_lone_agent_empty_body_errors() {
  local status=0
  ( main --no-pr "#sonnet" ) || status=$?
  assertEquals "agent tag alone has no body to fall back on" 1 "$status"
}

test_hashtag_flag_wins() {
  (
    unset HERDR_ENV
    wt() { log_call "wt" "$@"; printf '{"path":"%s"}\n' "$FAKE_WT"; }
    claude() { log_call "claude" "$@"; echo '{"branch": "feat/fix-bug", "name": "Fix bug"}'; }
    main --no-pr -a opus "#sonnet fix bug"
  )
  assert_called "claude --model opus" "explicit -a flag wins over #tag"
  assert_not_called "--model sonnet" "hashtag agent not used"
  assert_called "fix bug" "hashtag still stripped from prompt text"
}

test_no_agent_no_hashtag_errors() {
  local status=0
  ( main --no-pr "fix bug" ) || status=$?
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
    main --no-pr "@$promptfile"
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
    main --no-pr - <<< "#sonnet fix bug via stdin"
  )
  assert_called "claude --model sonnet" "sonnet resolved from stdin prompt"
  assert_called "fix bug via stdin" "tag stripped from stdin prompt"
}

test_default_harness_is_auto() {
  # INFER_HARNESS left at setUp's default ("auto") → resolves to claude (mock exists)
  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  claude() {
    log_call "claude" "$@"
    echo '{"branch": "feat/auto-default", "name": "Auto default"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet "use auto by default"

  assert_called "claude" "claude called for branch/name inference (auto-resolved from default)"
  assert_called "--model haiku" "auto-picked haiku model"
  assert_not_called "pi " "pi not called when auto resolves to claude"
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

  main --no-pr -a sonnet "use pi explicitly"

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

  INFER_HARNESS=opencode
  INFER_MODEL=""
  assertEquals "opencode/big-pickle" "$(resolve_infer_model)"

  INFER_HARNESS=claude
  INFER_MODEL="custom-model"
  assertEquals "custom-model" "$(resolve_infer_model)"

  INFER_HARNESS=pi
  INFER_MODEL="custom-model"
  assertEquals "custom-model" "$(resolve_infer_model)"

  INFER_HARNESS=opencode
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

  INFER_HARNESS=opencode
  assertTrue "opencode is valid" "ensure_valid_infer_harness"

  # auto with claude available (mock function exists)
  INFER_HARNESS=auto
  ensure_valid_infer_harness
  assertEquals "auto resolves to claude when claude is available" "claude" "$INFER_HARNESS"

  INFER_HARNESS=bogus
  local output status
  output=$(ensure_valid_infer_harness 2>&1) && status=$? || status=$?
  assertEquals "bogus harness is invalid" 1 "$status"
  echo "$output" | grep -qi 'unknown INFER_HARNESS' || fail "error message should mention unknown INFER_HARNESS"
}

test_auto_harness_resolves_opencode() {
  # claude NOT available → auto resolves to opencode
  INFER_HARNESS=auto
  (
    unset -f claude
    # Hide real claude binary (if installed); rely on opencode mock function
    PATH="" ensure_valid_infer_harness
    assertEquals "auto resolves to opencode when claude is absent" "opencode" "$INFER_HARNESS"
  )
}

test_ensure_dependencies_all_present() {
  ensure_dependencies || fail "ensure_dependencies failed when all deps present"
}

test_ensure_dependencies_missing_one() {
  local output status
  output=$(unset -f wt; PATH="" ensure_dependencies 2>&1) && status=$? || status=$?
  assertEquals "missing wt is error" 1 "$status"
  echo "$output" | grep -q "missing required dependencies:.* wt" || fail "error should mention missing wt"
  echo "$output" | grep -qi "Error:" || fail "error should say Error"
}

test_ensure_dependencies_missing_multiple() {
  local output status
  output=$(unset -f wt jq git; PATH="" ensure_dependencies 2>&1) && status=$? || status=$?
  assertEquals "all missing is error" 1 "$status"
  echo "$output" | grep -qE "missing.* wt( |\$)" || fail "error should mention wt"
  echo "$output" | grep -q " jq " || fail "error should mention jq"
  echo "$output" | grep -q " git" || fail "error should mention git"
}

test_main_fails_fast_on_missing_dependency() {
  local output status
  output=$(unset -f wt jq git claude pi; PATH="" main --no-pr -a sonnet "fix bug" 2>&1) && status=$? || status=$?

  assertEquals "main exits on missing dep" 2 "$status"
  echo "$output" | grep -qi "missing.*dependencies" || fail "error should mention missing dependencies"
  assert_not_called "pi " "pi never called when wt is missing"
  assert_not_called "claude " "claude never called when wt is missing"
  assert_not_called "opencode " "opencode never called when wt is missing"
}

test_auto_harness_neither_errors() {
  INFER_HARNESS=auto
  local output status
  output=$(unset -f claude opencode; PATH="" ensure_valid_infer_harness 2>&1) && status=$? || status=$?
  assertEquals "auto fails when neither binary is available" 1 "$status"
  echo "$output" | grep -qi 'neither.*claude.*opencode.*PATH' || fail "error message should mention missing binaries"
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

  main --no-pr -a sonnet "zellij integration"

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
  output=$(main --no-pr -a sonnet "zellij muxer display" 2>&1) || true

  echo "$output" | grep -qF 'muxer:    zellij' || fail "muxer displayed as zellij in output"

  unset ZELLIJ
}

test_get_muxer_type_tmux() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ
  export TMUX=/tmp/tmux-1000/default,1234,0
  assertEquals "tmux" "$(get_muxer_type)"
  unset TMUX
}

test_tmux_integration() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ
  export TMUX=/tmp/tmux-1000/default,1234,0
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/tmux-test", "name": "Tmux Test"}'
  }

  tmux() {
    log_call "tmux" "$@"
  }

  main --no-pr -a sonnet "tmux integration"

  assert_called "tmux new-window" "tmux new-window called"
  assert_called -- "-d" "tmux new-window detached"
  assert_called -- "-c $FAKE_WT" "tmux window with correct cwd"
  assert_called -- "-n Tmux Test" "tmux window with correct name"
  assert_called "bash -c bash" "tmux window runs cmdfile"
  assert_not_called "herdr " "herdr not called"
  assert_not_called "cmux " "cmux not called"
  assert_not_called "zellij " "zellij not called"

  unset TMUX
}

test_tmux_create_window_muxer_display() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ
  export TMUX=/tmp/tmux-1000/default,1234,0
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/tmux-muxer", "name": "Tmux Muxer"}'
  }

  tmux() {
    log_call "tmux" "$@"
  }

  local output
  output=$(main --no-pr -a sonnet "tmux muxer display" 2>&1) || true
  echo "$output" | grep -qF 'muxer:    tmux' || fail "muxer displayed as tmux in output"

  unset TMUX
}

test_invalid_infer_harness_fails_fast() {
  INFER_HARNESS=bogus

  local output status
  output=$(main --no-pr -a sonnet "should never run" 2>&1) && status=$? || status=$?

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

  main --no-pr -a sonnet fix bug

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

  main --no-pr -a sonnet - <<< "fix via stdin"

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

  main --no-pr -a sonnet "@$promptfile"

  assert_called "feat/file-test" "file prompt read via @file"
  assert_called "fix via file" "file content in prompt"
  rm -f "$promptfile"
}

test_branch_flag_skips_inference() {
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  # pi() must NOT be called when --branch is used
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "ignored", "name": "Ignored"}'
  }

  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet --branch feat/my-fix "fix stuff"

  assert_not_called "pi " "pi inference skipped when --branch used"
  assert_called "--create feat/my-fix" "worktree created on given branch"
  assert_called "--label My fix" "workspace name derived from branch"
}

test_branch_name_derivation() {
  assertEquals "Add redis cache" "$(derive_workspace_name "feat/add-redis-cache")"
  assertEquals "Fix bug" "$(derive_workspace_name "fix-bug")"
  assertEquals "Update deps" "$(derive_workspace_name "chore/update-deps")"
  assertEquals "My fix" "$(derive_workspace_name "feat/my-fix")"
  assertEquals "Test" "$(derive_workspace_name "test")"
  assertEquals "Some branch" "$(derive_workspace_name "feature/some_branch")"
  assertEquals "Abc" "$(derive_workspace_name "ABC")"
  # Collapse consecutive separators
  assertEquals "My fix" "$(derive_workspace_name "feat/my--fix")"
  assertEquals "Foo" "$(derive_workspace_name "feat/_foo")"
}

test_branch_short_flag() {
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "ignored", "name": "Ignored"}'
  }

  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet -b feat/short-flag "fix stuff"

  assert_not_called "pi " "pi inference skipped with -b"
  assert_called "--create feat/short-flag" "worktree created via -b"
}

test_base_long_flag_only() {
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/some-fix", "name": "Some fix"}'
  }

  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet --base main "fix stuff"

  assert_called "--base main" "--base flag passed to wt"
  assert_called "pi " "pi still called for inference"
}

test_branch_rejects_invalid() {
  # Override git to reject "has space" as invalid branch name; succeed for everything else
  git() {
    log_call "git" "$@"
    if [[ "$*" == *"check-ref-format"* ]] && [[ "$*" == *"has space"* ]]; then
      return 1
    fi
    return 0
  }

  local output status
  output=$(main --no-pr -a sonnet --branch "has space" "fix stuff" 2>&1) && status=$? || status=$?

  assertEquals "main exits non-zero on invalid branch" 1 "$status"
  echo "$output" | grep -qi 'invalid branch' || fail "error message should mention invalid branch"
}

test_branch_skips_harness_check() {
  # --branch should not require INFER_HARNESS to be installed
  INFER_HARNESS=bogus
  INFER_MODEL=""

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

  main --no-pr -a sonnet --branch feat/direct-branch "fix stuff"

  assert_called "--create feat/direct-branch" "worktree created without infer harness"
  assert_not_called "pi " "pi never called"
  assert_not_called "claude " "claude never called"
}

test_help_omits_p_flag() {
  local output
  output=$(show_help)

  # OPTIONS section must not list -p/--prompt as a flag
  ! grep -q -- '-p, --prompt' <<<"$output" || fail "show_help must not list -p flag"
  # But an agent description like 'opencode --auto --prompt' may mention --prompt
  # legitimately — only the flag definition line should not exist.

  # New flags present
  grep -q -- '-b, --branch' <<<"$output" || fail "show_help must list -b/--branch"
  grep -q -- '--base' <<<"$output" || fail "show_help must list --base (long only)"
  # --base must NOT have a short flag
  ! grep -q -- '-b, --base' <<<"$output" || fail "show_help must not list -b as --base short flag"
}

# --- iTerm2 tests ---

test_is_using_iterm2_detects_TERM_PROGRAM() {
  TERM_PROGRAM="iTerm.app"
  assertTrue "is_using_iterm2 returns true" "is_using_iterm2"
  unset TERM_PROGRAM
}

test_is_using_iterm2_negative() {
  unset TERM_PROGRAM
  assertFalse "is_using_iterm2 returns false when unset" "is_using_iterm2"
  TERM_PROGRAM="Terminal.app"
  assertFalse "is_using_iterm2 returns false for other terminal" "is_using_iterm2"
  unset TERM_PROGRAM
}

test_get_muxer_type_iterm2() {
  # Simulate iTerm2 environment: TERM_PROGRAM set, no cmux/herdr/zellij
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ TMUX
  export TERM_PROGRAM="iTerm.app"
  assertEquals "iterm2" "$(get_muxer_type)"
  unset TERM_PROGRAM
}

test_get_muxer_type_iterm2_lower_priority_than_muxers() {
  # iterm2 should lose to cmux
  export CMUX_WORKSPACE_ID=test
  export TERM_PROGRAM="iTerm.app"
  assertEquals "cmux" "$(get_muxer_type)"
  unset CMUX_WORKSPACE_ID TERM_PROGRAM
}

test_iterm2_create_workspace() {
  local fake_wt="/tmp/wt-test-workspace" fake_cmdfile="/tmp/wt-cmd-ABCDEF"

  # Mock osascript: log args
  osascript() {
    log_call "osascript" "$@"
  }

  iterm2_create_workspace "$fake_wt" "Test Name" "$fake_cmdfile"

  assert_called "osascript" "osascript was called"
  # Paths and display name are passed as osascript argv
  assert_called "$fake_wt" "worktree_path passed to osascript"
  assert_called "Test Name" "display_name passed to osascript"
  assert_called "$fake_cmdfile" "cmdfile passed to osascript"
}

test_launch_agent_iterm2() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ TMUX
  export TERM_PROGRAM="iTerm.app"
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/iterm2-test", "name": "iTerm2 Test"}'
  }

  osascript() {
    log_call "osascript" "$@"
  }

  main --no-pr -a sonnet "iterm2 integration"

  assert_called "osascript" "osascript called for iTerm2 launch"
  assert_called "feat/iterm2-test" "correct branch"
  assert_not_called "herdr " "herdr not called"
  assert_not_called "cmux " "cmux not called"
  assert_not_called "zellij " "zellij not called"

  unset TERM_PROGRAM
}

test_tmux_priority_over_iterm2() {
  # tmux inside iTerm2: tmux should win
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ
  export TERM_PROGRAM="iTerm.app"
  export TMUX="/tmp/tmux-1000/default,1234,0"

  assertEquals "tmux" "$(get_muxer_type)"

  unset TERM_PROGRAM TMUX
}

test_infer_harness_opencode() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ TMUX
  INFER_HARNESS=opencode

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  opencode() {
    log_call "opencode" "$@"
    cat <<'NDJSON'
{"type":"text","part":{"type":"text","text":"{\"branch\": \"feat/opencode-test\", \"name\": \"Opencode Test\"}"}}
NDJSON
  }

  main --no-pr -a sonnet "opencode harness test"

  assert_called "opencode run" "opencode called for inference"
  assert_called "--format json" "opencode called with --format json"
  assert_called "feat/opencode-test" "branch inferred by opencode"
  assert_not_called "pi -p" "pi not called for inference"
}

test_iterm2_muxer_display() {
  unset HERDR_ENV CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_PORT ZELLIJ TMUX
  export TERM_PROGRAM="iTerm.app"
  INFER_HARNESS=pi

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }

  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/iterm2-disp", "name": "iTerm2 Display"}'
  }

  osascript() {
    log_call "osascript" "$@"
  }

  local output
  output=$(main --no-pr -a sonnet "iterm2 display" 2>&1) || true

  echo "$output" | grep -qF 'muxer:    iterm2' || fail "muxer displayed as iterm2 in output: $output"

  unset TERM_PROGRAM
}

test_legacy_pr_flags_still_work() {
  # Old alias --no-create-pr still parses and creates worktree
  INFER_HARNESS=pi
  pi() {
    log_call "pi" "$@"
    echo '{"branch": "feat/legacy-test", "name": "Legacy Test"}'
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

  main --no-create-pr -a sonnet "legacy test"

  assert_called "--create feat/legacy-test" "legacy --no-create-pr flag parsed, worktree created"
}

test_BRANCH_PREFIX_in_print_default_config() {
  local output
  output=$(print_default_config)
  grep -q "^BRANCH_PREFIX='feat'$" <<<"$output" || fail "missing BRANCH_PREFIX in print_default_config"
  grep -q 'branch:.*%PREFIX%/' <<<"$output" || fail "INFER_PROMPT must contain %PREFIX% placeholder"
}

test_empty_BRANCH_PREFIX_falls_back() {
  INFER_HARNESS=pi
  local BRANCH_PREFIX=""

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    # Verify prompt contains fallback prefix feat/
    [[ "$*" == *'"feat/"'* || "$*" == *'feat/{slug}'* ]] || { echo 'ERROR: prompt missing feat/' >&2; return 1; }
    echo '{"branch": "feat/fallback-test", "name": "Fallback Test"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet "add fallback test"

  # Empty BRANCH_PREFIX should fall back to feat in the prompt
  assert_called "pi " "pi called for inference"
  assert_not_called "%PREFIX%" "%PREFIX% literal not sent to model"
}

test_BRANCH_PREFIX_trailing_slash_stripped() {
  INFER_HARNESS=pi
  local BRANCH_PREFIX="feat/"

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    # The prompt should NOT contain feat// (double slash from "feat/" + "/")
    [[ "$*" != *'feat//'* ]] || { echo 'ERROR: double slash in prompt' >&2; return 1; }
    echo '{"branch": "feat/slash-test", "name": "Slash Test"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet "add slash test"

  assert_called "pi " "pi called for inference"
  assert_not_called "feat//" "no double slash in prompt"
}

test_infer_prompt_uses_custom_prefix() {
  INFER_HARNESS=pi
  local BRANCH_PREFIX="rico"

  wt() {
    log_call "wt" "$@"
    printf '{"path":"%s"}\n' "$FAKE_WT"
  }
  pi() {
    log_call "pi" "$@"
    # Verify prompt contains custom prefix rico/
    [[ "$*" == *'"rico/"'* || "$*" == *'rico/{slug}'* ]] || { echo 'ERROR: prompt missing rico/' >&2; return 1; }
    echo '{"branch": "rico/custom-prefix", "name": "Custom Prefix"}'
  }
  herdr() {
    log_call "herdr" "$@"
    if [[ "$*" == *"workspace create"* ]]; then
      echo '{"result":{"root_pane":{"pane_id":"pane-99"}}}'
    fi
  }

  main --no-pr -a sonnet "add custom prefix test"

  assert_called "pi " "pi called for inference"
  # Prompt verified inside pi() mock (rico/ check)
}

test_legacy_pr_flags_hidden_from_help() {
  local help_text
  help_text=$(main --help 2>&1)

  echo "$help_text" | grep -qF -- '--pr' || fail "--pr should appear in help"
  echo "$help_text" | grep -qF -- '--no-pr' || fail "--no-pr should appear in help"
  ! echo "$help_text" | grep -qF -- '--create-pr' || fail "--create-pr should NOT appear in help"
  ! echo "$help_text" | grep -qF -- '--no-create-pr' || fail "--no-create-pr should NOT appear in help"
}

# --- shunit2 bootstrap ---
# shellcheck disable=SC1091
source "$TEST_DIR/shunit2"
