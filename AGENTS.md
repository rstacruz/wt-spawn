## Tests

```sh
just test
```

First run downloads shunit2 to `tests/shunit2` (gitignored). Tests mock external commands via function shadowing — no real side effects.
