# NexDB Mac servers

Build scripts for the server programs [NexDB](https://db.nexiodev.site) installs on Macs:
Apache, nginx, PHP, MySQL, PostgreSQL, Redis, Node.js and Mailpit.

Each program is built from its official source (or official release) for **Intel** and
**Apple Silicon**, to run on **macOS 12 Monterey and newer**, with its libraries inside its own
folder. A check fails the build if any file needs a newer macOS or loads a library from outside.

- `versions.txt`: the versions to build, one program per line.
- `scripts/build.sh <program> <version>`: builds one program on the Mac it runs on.
- Actions → **Build Mac servers** → Run workflow: builds everything and publishes a release.

The programs keep their own licenses (Apache 2.0, PHP License, GPL 2.0 for MySQL,
PostgreSQL License, BSD/RSAL for Redis, MIT for Node.js and Mailpit).
