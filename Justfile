shunit2_url := "https://raw.githubusercontent.com/kward/shunit2/v2.1.8/shunit2"
shunit2_path := "tests/shunit2"

[no-exit-message]
_ensure-shunit2:
  @if [ ! -f "{{shunit2_path}}" ]; then \
    echo "Downloading shunit2 v2.1.8..."; \
    curl -fsSL -o "{{shunit2_path}}" "{{shunit2_url}}" || { rm -f "{{shunit2_path}}"; exit 1; }; \
    chmod +x "{{shunit2_path}}"; \
  fi

test: _ensure-shunit2
  cd tests && bash test_wt_spawn.sh
