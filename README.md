# Docker Scripts

A collection of handy Docker-related shell scripts to simplify common Docker tasks such as creating and restoring snapshots, running Liferay Portal and DXP Docker containers, and managing backups.

---

## Compatibility & Intended Use

The snapshot scripts in this repo are designed to work **together** with the run scripts:

- `create-docker-snapshot.sh` and `restore-docker-snapshot.sh` are intended for **Liferay containers and folder structures created by** `run-liferay-portal-docker.sh` or `run-liferay-dxp-docker.sh`.
- They assume the standard project layout these run scripts create (for example `files/`, `data/`, `osgi/`, `deploy/`, `backups/`).
- Advanced users can point `--root` at any folder that matches this layout, but the simplest path is to use the provided run scripts first.

---

## Liferay Developer License Setup

If you have a Liferay **XML development license**, you can add it once and have it automatically applied to all newly created Liferay containers.

Place your XML license file in the following directory:

```text
7.4-common/deploy
```

When you run `run-liferay-portal-docker.sh` or `run-liferay-dxp-docker.sh`, the scripts detect the license and automatically copy it into the container during setup.

You can also add configuration files (for example `portal-ext.properties`, `system-ext.properties`, or other `.properties` files) to the same directory. These will be copied to the container as well, allowing your preferred default configuration to be applied to **all newly created Liferay containers**.

This means you can maintain a consistent developer setup, with both your license and configuration automatically provisioned whenever you create a new environment.

---

## Liferay Home Folder Mapping & Purpose

For background on the standard layout, see Liferay’s docs on **Liferay Home**:

- <https://learn.liferay.com/w/dxp/self-hosted-installation-and-upgrades/reference/liferay-home>

Our scripts create a project root that mirrors Liferay Home and bind‑mount these folders into the container:

```text
Host folder                              → Container path
---------------------------------------------------------------------------------
<root>/data                              → /opt/liferay/data
<root>/deploy                            → /mnt/liferay/deploy
<root>/files                             → /mnt/liferay/files
<root>/osgi/configs                      → /opt/liferay/osgi/configs
<root>/osgi/state                        → /opt/liferay/osgi/state
<root>/osgi/client-extensions            → /opt/liferay/osgi/client-extensions
<root>/scripts                           → /mnt/liferay/scripts
<root>/backups                           → (host-only; snapshots live here)
```

What each folder is for:

- **data/**: Persistent Liferay data (file repository, indexes). For Hypersonic (dev only), embedded DB files live here. In Liferay Cloud format backups we copy only `data/document_library` as `doclib/`.
- **deploy/**: Auto‑deploy drop‑in; JAR/WAR/LPKG placed here are deployed automatically by the running server.
- **files/**: Host‑side overlay for config/licensing and other one‑off assets copied in at startup (e.g., `portal-ext.properties`, license XML). Useful for bootstrapping new environments.
- **osgi/configs**: OSGi component configurations persisted on the host and applied on startup.
- **osgi/state**: Runtime state cache for installed bundles; persisting this speeds up restarts.
- **osgi/client-extensions**: Dedicated location for **zip‑deployable Client Extensions** so you can mount them once and have them available in the container.
- **scripts/**: Optional helper scripts mounted into the container.
- **backups/**: Host‑side snapshots created by `create-docker-snapshot.sh`.

## Quick Start

To get started quickly, clone the repository and run any of the scripts directly:

```bash
git clone https://github.com/yourusername/docker-scripts.git
cd docker-scripts

# Example: Create a Docker snapshot
./create-docker-snapshot.sh

# Example: Restore a Docker snapshot
./restore-docker-snapshot.sh --verbose

# Example: Run a Liferay Portal Docker container
./run-liferay-portal-docker.sh

# Example: Run a Liferay DXP Docker container
./run-liferay-dxp-docker.sh
```

Make sure the scripts have execute permissions:

```bash
chmod +x *.sh
```

---

## Scripts Overview

### create-docker-snapshot.sh

Creates a timestamped snapshot of a **Liferay** environment (database + files), compatible with both local and Liferay Cloud (PaaS) formats. It works with environments created by `run-liferay-portal-docker.sh` or `run-liferay-dxp-docker.sh`.

**Usage:**

```bash
./create-docker-snapshot.sh [OPTIONS]
```

**Options:**

| Option | Description | Default |
|---|---|---|
| `-r, --root <path>` | Liferay project root (expects files/, data/, osgi/, deploy/) | current directory (prompted if interactive) |
| `-b, --backups-dir <path>` | Backups directory (relative or absolute) | `<root>/backups` |
| `-c, --container <name>` | Override container name | derived from basename of `<root>` (dots → dashes) |
| `-n, --name <text>` | Optional snapshot name stored in `meta` | none |
| `--no-name` | Skip name prompt and store no name | prompt in interactive mode |
| `--db-only` / `--files-only` | Dump only DB or only filesystem | both |
| `--compression <gzip\|xz\|none>` | Compression used for DB dumps and tar | `gzip` |
| `--prefix <text>` | Prefix added to snapshot folder name | none |
| `--format <standard\|liferay-cloud>` | Backup layout. If `liferay-cloud`, emits `database.gz` (plain SQL, no owner/privileges) and `volume.tgz` (tar.gz of `data/document_library`) | `standard` |
| `--verify` | Validate created archives (gzip/xz integrity, tar list) | off |
| `--retention <N>` | Keep only newest N backups (older pruned; if `--prefix` is set, pruning applies to that prefix only) | unlimited |
| `-s, --stop` / `--no-stop` | Stop container during snapshot and restart after if it was running | stop |
| `--pg-host/--pg-port` | Override PostgreSQL host/port if DB is PostgreSQL | parsed from JDBC, host.docker.internal→localhost, port 5432 |
| `--my-host/--my-port` | Override MySQL host/port if DB is MySQL | parsed from JDBC, host.docker.internal→localhost, port 3306 |
| `--tag key=value` (repeatable) | Add metadata tags stored as `tag.<key>=<value>` in `meta` | none |
| `--non-interactive` | No prompts; apply defaults and flags | off |
| `--quiet` / `--verbose` | Adjust logging verbosity | normal |

#### What gets created

Depending on your selected format:

**Standard format (default):**

- `meta` — text file with backup metadata (includes `meta_version`, `type`, `format`, `db_dump`, `files_archive`, and optionally `name`/`tag.*`)
- If PostgreSQL: `db-postgresql.sql.gz`
- If MySQL: `db-mysql.sql.gz`
- Filesystem archive: `files.tar.gz` (contains `files/`, `scripts/`, `osgi/`, `data/`, `deploy/`)

**Liferay Cloud format:**

- `meta` — includes `meta_version`, `format=liferay-cloud`, `db_dump=database.gz`, `files_archive=volume.tgz` (plus `type` and optional `name`/`tag.*`)
- `database.gz` — plain SQL dump (no owner/privilege statements)
- `volume.tgz` — tar.gz of the `data/document_library` directory

---

### restore-docker-snapshot.sh

Restores a snapshot created by `create-docker-snapshot.sh` into a matching **Liferay** project root. Supports both standard and Liferay Cloud backups. For Cloud backups, only `database.gz` and `volume.tgz` are restored automatically; other files must be applied manually.

**Usage:**

```bash
./restore-docker-snapshot.sh [OPTIONS]
```

**Options:**

| Option | Description | Default |
|---|---|---|
| `-r, --root <path>` | Liferay project root | current directory (prompted if interactive) |
| `-b, --backups-dir <path>` | Backups directory | `<root>/backups` |
| `-c, --container <name>` | Override container name | derived from basename of `<root>` |
| `-i, --index <N>` | Select backup by numeric index (1 = newest) | newest in non-interactive; prompt in interactive |
| `--checkpoint <folder>` | Select backup by exact folder name | none |
| `--no-list` | Suppress listing of backups | listed in interactive; suppressed in non-interactive |
| `-s, --stop` / `--no-stop` | Stop container during restore and restart after if it was running | stop |
| `--delete-after` / `--keep-checkpoint` | Delete checkpoint after successful restore or keep it | keep |
| `--pg-host/--pg-port` | Override PostgreSQL host/port when restoring DB | parsed from JDBC, host.docker.internal→localhost, port 5432 |
| `--my-host/--my-port` | Override MySQL host/port when restoring DB | parsed from JDBC, host.docker.internal→localhost, port 3306 |
| `--format <standard\|liferay-cloud>` | Force interpret backup layout; normally auto-detected | auto-detected |
| `--min-meta-version <N>` | Require at least meta_version N (default 2) | 2 |
| `--allow-legacy` | Ignore meta_version check (use with caution) | off |
| `--non-interactive` | No prompts; defaults applied | off |
| `--quiet` / `--verbose` | Adjust logging verbosity | normal |

**Notes:**

- The restore script first honors file hints in `meta` (`db_dump` and `files_archive`). If not present, it auto-detects using common filename patterns.

- Use `--verbose` to see a summary of detected candidates and the final files chosen, for example:
  - `snapshot: type=postgresql format=standard`
  - `meta hint: db_dump=/path/to/backup/db-postgresql.sql.gz`
  - `candidate postgres dump: /path/to/backup/db-postgresql.sql.gz`
  - `using database dump: /path/to/backup/db-postgresql.sql.gz`
  - `using files archive: /path/to/backup/files.tar.gz`

---

### Liferay Cloud Compatibility

When restoring a Liferay Cloud-format backup:

- Only `database.gz` and `volume.tgz` are applied.
- Configuration, OSGi state, and scripts must be restored manually.
- Cloud backups are only supported for PostgreSQL and MySQL databases.

The `meta` file records `db_dump=database.gz` and `files_archive=volume.tgz` so restores are self-describing.

---

### run-liferay-portal-docker.sh

Runs a Liferay Portal Docker container with default or specified options.

**Usage:**

```bash
./run-liferay-portal-docker.sh [OPTIONS]
```

**Options:**

| Option | Description | Default |
|---|---|---|
| `-t, --tag <tag>` | Docker image tag to run | auto-detected (based on release type for DXP; LTS for Portal) |
| `-r, --root <path>` | Project root where volumes/configs are created | `./<tag>` if non-interactive, otherwise prompted |
| `-c, --container <name>` | Container name | derived from basename of `<root>` |
| `-p, --port <port>` | Host port to map to 8080 in the container | `8080` |
| `--db <postgresql\|mysql\|hypersonic>` | Choose database | prompted (hypersonic in non-interactive if not set) |
| `--jdbc-username <user>` | DB username (external DB) | prompted |
| `--jdbc-password <pass>` | DB password (external DB) | prompted |
| `--recreate-db` | Drop and recreate DB if it exists | off |
| `--host-network` / `--no-host-network` | Use or avoid host networking | disabled |
| `--disable-zip64` / `--enable-zip64` | Toggle Zip64 extra field validation | disabled |
| `--remove-after` / `--keep-container` | Remove the container after exit or keep it | keep |
| `--delete-state` | Delete `osgi/state` before starting if container exists | off |
| `--non-interactive` | No prompts; apply defaults | off |
| `--quiet` / `--verbose` | Adjust logging verbosity | normal |

---

### run-liferay-dxp-docker.sh

Runs a Liferay DXP Docker container with default or specified options.

**Usage:**

```bash
./run-liferay-dxp-docker.sh [OPTIONS]
```

**Options:**

| Option | Description | Default |
|---|---|---|
| `-t, --tag <tag>` | Docker image tag to run | auto-detected (based on release type for DXP; LTS for Portal) |
| `-r, --root <path>` | Project root where volumes/configs are created | `./<tag>` if non-interactive, otherwise prompted |
| `-c, --container <name>` | Container name | derived from basename of `<root>` |
| `-p, --port <port>` | Host port to map to 8080 in the container | `8080` |
| `--db <postgresql\|mysql\|hypersonic>` | Choose database | prompted (hypersonic in non-interactive if not set) |
| `--jdbc-username <user>` | DB username (external DB) | prompted |
| `--jdbc-password <pass>` | DB password (external DB) | prompted |
| `--recreate-db` | Drop and recreate DB if it exists | off |
| `--host-network` / `--no-host-network` | Use or avoid host networking | disabled |
| `--disable-zip64` / `--enable-zip64` | Toggle Zip64 extra field validation | disabled |
| `--remove-after` / `--keep-container` | Remove the container after exit or keep it | keep |
| `--delete-state` | Delete `osgi/state` before starting if container exists | off |
| `--non-interactive` | No prompts; apply defaults | off |
| `--quiet` / `--verbose` | Adjust logging verbosity | normal |

---

## Defaults for Non-Interactive Mode

All scripts support non-interactive mode. When `--non-interactive` is used:

- No prompts are displayed.
- `--root` defaults to the current directory.
- For `create-docker-snapshot.sh`: container is stopped by default (unless `--no-stop`), compression defaults to `gzip`, snapshot folder is `[prefix-]YYYYMMDD-HHMMSS/` under `<root>/backups`, and newest-only retention is applied only if `--retention` is provided.
- For `restore-docker-snapshot.sh`: the newest backup under `<root>/backups` is chosen automatically unless `--index` or `--checkpoint` is provided; container is stopped by default (unless `--no-stop`); checkpoint is kept by default (unless `--delete-after`).
- `--format` defaults to `standard` unless explicitly set.

When used outside of the Liferay project layout produced by the run scripts, pass `--root` to point at a compatible folder structure.

---

## Metadata and Backup Structure

Backups live under:

```text
<root>/backups/
└── [prefix-]YYYYMMDD-HHMMSS/
    ├── meta
    ├── db-postgresql.sql.gz   # or db-mysql.sql.gz, or filesystem.tar.gz if Hypersonic
    └── files.tar.gz
```

The create script writes `meta_version` (currently 2); the restore script enforces a minimum version unless `--allow-legacy` is used.

`meta` contains at least:

```text
meta_version=2
type=postgresql|mysql|hypersonic
format=standard|liferay-cloud
name=Optional friendly name (if provided)
# Filenames are relative to the checkpoint folder unless absolute
db_dump=db-postgresql.sql.gz          # or db-mysql.sql.gz, database.gz for liferay-cloud
files_archive=files.tar.gz            # or volume.tgz for liferay-cloud
# any number of tags as key/value pairs
tag.environment=dev
tag.branch=main
```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Author

Developed and maintained by Peter Richards - [peter.richards@liferay.com](mailto:peter.richards@liferay.com)

---

Thank you for using Docker Scripts! Feel free to contribute or report issues on the repository.

---

## 🧯 Troubleshooting

### Docker socket permission errors

If you encounter errors like `Cannot connect to the Docker daemon`, ensure that Docker Desktop is running and your user has permission to access the Docker socket. On macOS, this is usually fixed by restarting Docker Desktop.

### Command not found

If running any script results in `command not found`, ensure you’ve given execute permissions to the files:

```bash
chmod +x *.sh
```

### Database authentication issues

If a PostgreSQL or MySQL connection fails during backup or restore, verify the credentials and connection details. You can test manually with:

```bash
psql -h localhost -U youruser -d yourdb
mysql -h localhost -u youruser -p yourdb
```

### Missing dependencies

If you see errors about missing `jq`, `curl`, or `psql`, install them using:

```bash
brew install jq coreutils postgresql mysql
```

### macOS date incompatibility

If you encounter errors involving `date` or timestamps, install GNU coreutils:

```bash
brew install coreutils
```

and use `gdate` instead of `date` where required.

### Docker volume permission issues

If you receive permission errors while creating or restoring volumes, run the script with elevated privileges or adjust ownership using:

```bash
sudo chown -R $(whoami) ./data ./backups
```

### General debugging

You can enable verbose output for most scripts by passing the `--verbose` flag to see expanded command details.

```bash
./create-docker-snapshot.sh --verbose
```

#### Example: Uploading a Liferay Cloud Backup

When using the Liferay Cloud format, you can upload your generated files directly using the DXP Cloud Backup API. Replace the URL and token as appropriate for your environment:

```bash
curl -X POST \
  https://your-project.your-env.lfr.cloud/backup/upload \
  -H 'Content-Type: multipart/form-data' \
  -H 'dxpcloud-authorization: Bearer TOKEN' \
  -F 'database=@/path/to/your/backup/database.gz' \
  -F 'volume=@/path/to/your/backup/volume.tgz'
```

This matches the output of `create-docker-snapshot.sh` when using `--format liferay-cloud`.