# Circuit Convert — Windows proof (2026-09-18)

`proof/<app>/` is the output of `circuit --convert <app repo> --verify` run on a Mac
(compiler-checked in the simulated Windows configuration). The workflow in this branch runs
`circuit --reverify` on a real `windows-latest` runner: the native Windows Swift compiler is
the judge, anything it rejects is isolated the same way, and the final package is built once
more from clean. Artifacts carry the verified package + `conversion.json` per app.

This branch is an orphan: it shares no history with the product and can be deleted at will.
