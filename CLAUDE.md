# Circuit — Claude context

READ FIRST (canonical company truth — do not re-ask the founder):
- ~/BlackLabel-Team/CONTEXT/COMPANY.md   (identity, metrics, charter rules, traps, founder gates)
- ~/BlackLabel-Team/CONTEXT/BRIEF-TEMPLATES.md  (structure any terse task before executing)
- ~/BlackLabel-Team/CONTEXT/EVALS.md     (ship gates — nothing revenue-facing ships without one)
- ~/ATLAS.md (directory map)

THIS REPO: Repo name = BlackLabelCircuit (naming drift). Windows spike branch active.

DEV PORT (hands-off :8923): `:8923` is the LIVE Circuit instance. `server.js` defaults to 8923 and
auto-increments ONLY on EADDRINUSE — that is not a safety net. With :8923 empty, a bare
`node server.js <repo>` BINDS the hands-off port. Dev runs MUST pass an explicit port:
`node server.js <repo> --port 8924`. Tests must never bind 8923 — enforced for every test file
(including new ones) by the guard in test/regressions.test.js; naming the port in a comment or a
test title is fine, a bare literal or a whitespace-free string like '8923'/'http://…:8923' fails.
(README.md line 15 documents the bare command for CUSTOMERS — correct there, not for dev.)

NON-NEGOTIABLE: §5.1 zero fabrication (verify numbers via psql :5433 / STATE/truth.json);
§3 owner-only gates = money, legal, Apple submit, investors, irreversible ship;
§5.5 no new paid purchases. Verify before claiming done — run the check, paste the output.
