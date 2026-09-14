# Portable Windows bundle — assembly record

`BlackLabelCircuit-portable-win-x64.zip` = `BlackLabelCircuit/BlackLabelCircuit.exe` (unchanged binary from the
2026.08.29 portable release, catalog sha 2A5218C8…, built outside this history — commit 6c23f3ad is not in this
repo) + the two files in this directory.

Assemble with `python3 windows/portable/assemble.py <previous-portable.zip> <out.zip>`: it copies every entry of the
previous zip except `README.txt` and `Launch Circuit.cmd`, which are taken from here (CRLF, as shipped).

2026-09-14: launcher now opens the buyer interface after starting the service (the README always promised that;
the hosted-runner execution test showed it never did), README says so honestly and asks for a Git repository.
Known, not fixed here: pointed at a folder that is not a repository the service prints "analyzed 0 files … grade
A+ (100)" — that is in the executable, not the launcher.
