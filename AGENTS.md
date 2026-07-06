## Tests

```sh
just test
```

First run downloads shunit2 to `tests/shunit2` (gitignored). Tests mock external commands via function shadowing — no real side effects.

## README examples

Agent config examples in README.md must match the defaults in `wt-spawn`.
When adding or changing agents, update the README config block to match
`--print-default-config` output.
