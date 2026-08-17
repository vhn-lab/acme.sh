# Avaya IP Office integration

This directory contains fork-specific integration code for using acme.sh with Avaya IP Office.

## Design rules

- Keep Avaya-specific code isolated under `custom/avaya/` whenever possible.
- Do not modify upstream acme.sh files unless there is no clean alternative.
- Never store private keys, certificate private material, passwords, API tokens, customer information, public/private IP addresses, or production-specific secrets in this repository.
- All changes must be proposed through a pull request and pass the required validation checks before merging into `master`.
- `master` represents the approved version of this fork.
- `update/upstream-review` is automation-owned and must not contain manual commits.
- The built-in `--upgrade` command downloads only from the reviewed
  `vhn-lab/acme.sh` fork. Official upstream changes enter through the review
  workflow above, never directly on a LAB host.

## Planned integration

The Avaya-specific deployment/renewal mechanism will be documented and implemented here after the exact IP Office certificate import/deployment procedure has been validated.

## Configuration model

Production configuration and secrets are stored outside the Git checkout, under
`/etc/acme-avaya/` by default. Example files in this directory contain fictitious
values only.

`config.example` contains global `KEY=value` settings. The deployment engine
parses a fixed allowlist of keys and never executes the file with `source` or `.`.

`targets.example.csv` declares one deployment target per line:

```text
enabled;type;name;host;sshUser;serverIp;certificateProfile;role
```

- `enabled`: `yes` or `no`.
- `type`: `ipo`. Other Avaya product types are outside the current scope.
- `name`: unique label used in logs and state files.
- `host`: DNS name or IP address used for SSH.
- `sshUser`: remote account dedicated to the target type.
- `serverIp`: explicit IPv4 address passed to Avaya `gen_certs.sh`; it is never
  inferred from remote interfaces.
- `certificateProfile`: groups targets that receive the same certificate.
- `role`: `standalone`, `primary`, or `secondary`.

This model supports one or two IP Office systems without duplicating deployment
scripts. It also allows the two systems to use separate certificates by assigning
different certificate profiles.

The example enables one IP Office system and keeps a second system disabled. Set
the second target to `enabled=yes` only after it is available in the LAB and its
deployment procedure has been validated.

ASBCE integration is intentionally deferred until representative ASBCE systems
are available in the LAB.

## Initial ACME validation

The initial LAB validation uses manual DNS-01 and the ACME staging environment.
No DNS provider credentials are stored or used by this integration. See
`MANUAL-DNS01-TEST.md` for the guarded procedure.

Manual DNS mode cannot renew certificates unattended. Automated issuance and
renewal remain out of scope until a DNS API integration can be tested safely.

## LAB deployment findings

- IP Office certificates must use RSA 2048.
- On systems using OpenSSL 3, build the import archive with the default modern
  PKCS12 compatibility mode. The optional `--compatibility legacy` mode is only
  for older targets whose Avaya import command can read legacy PKCS12 files.
- Some Avaya application keystores still use RC2. On OpenSSL 3, the installer
  scopes `custom/avaya/openssl-legacy.cnf` to `gen_certs.sh` only, activating
  both the default and legacy providers. It does not alter the system OpenSSL
  configuration or enable legacy algorithms for unrelated processes.
- Transactional backups are retained under
  `/root/orange/script/acme.sh/avaya-backups/ipo-<UTC timestamp>-<PID>/`.
  They contain only the active `server.pem`, `cert.pem`, `key.pem`, CA material,
  and any pre-existing import file. Application keystores are not copied.
- A completed Avaya distribution has `.distrib_complete` present and
  `.distrib_inprogress` absent under `/opt/Avaya/certs/`.
- Validate certificate fingerprints on ports 411, 443, 5061, 7070
  (WebManager), 52233 (WebLM), and 9443 (one-X Portal HTTPS).
- Port 7071 is WebControl. When `/opt/Avaya/certs/.wcp_no_restart` exists,
  Avaya copies the new certificate to disk but deliberately does not restart
  WebControl. The running process continues serving the certificate loaded at
  startup. After a successful distribution, the installation adapter restarts
  `webcontrol.service` under the existing explicit
  `--acknowledge-service-restarts` authorization, verifies that it is active,
  and waits for a stable `.distrib_complete` state. This final wait is required
  because restarted Avaya components can trigger another background distribution.

## Controlled remote deployment

`avaya-deploy.sh` supports planning and explicitly authorized application. A
real deployment requires all three safeguards: `--apply`,
`--acknowledge-service-restarts`, and a root-readable password file with mode
0400 or 0600. For example:

```sh
custom/avaya/avaya-deploy.sh \
  --apply --acknowledge-service-restarts \
  --config /etc/acme-avaya/config \
  --profile voice-edge \
  --cert /path/to/cert.pem \
  --key /path/to/key.pem \
  --fullchain /path/to/fullchain.pem \
  --expected-name ipo.example.invalid \
  --password-file /run/acme-avaya/p12-password
```

The remote helper uses BatchMode, strict host-key checking, the configured SSH
timeout, and a private `mktemp` staging directory. It removes the remote payload
on exit and records a local fingerprint only after endpoint verification. In
apply mode, an exclusive `flock` on `LOCK_FILE` prevents concurrent deployments.
