# Circuit Convert — Windows proof (2026-09-18)

`proof/<app>/` is the output of `circuit --convert <app repo> --verify` run on a Mac
(compiler-checked in the simulated Windows configuration). The workflow in this branch runs
`circuit --reverify` on a real `windows-latest` runner: the native Windows Swift compiler is
the judge, anything it rejects is isolated the same way, and the final package is built once
more from clean. Artifacts carry the verified package + `conversion.json` per app.

This branch is an orphan: it shares no history with the product and can be deleted at will.

## Branch convert-proof/20260918-keychain

The second round. `circuit/` is Circuit at f035404: CircuitPortKit gains the Keychain for
Windows (Credential Manager), the Darwin rewrite stops importing WinSDK (its UUID made
Foundation's ambiguous), Combine and Keychain names used without an import get the import,
and a module the platform lacks costs its import instead of the whole file.

- `kit-selftest-windows` builds the kit as its own module and runs the Keychain calls exactly
  as converted apps make them against the real Windows Credential Manager; `cmdkey` checks
  from outside what the test left behind.
- `proof/<app>` — all nine apps converted by the new Circuit.
- `proof/ace-before`, `proof/circuit-before` — the same input converted by the earlier
  Circuit (698fa1c, `circuit-before/`) and re-verified by it, because those two sources had
  changed since the first round. The other seven were unchanged since their first-round
  verdicts (branch convert-proof/20260918), which stay their before.
