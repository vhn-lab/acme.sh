# Avaya IP Office integration

This directory contains fork-specific integration code for using acme.sh with Avaya IP Office.

## Design rules

- Keep Avaya-specific code isolated under `custom/avaya/` whenever possible.
- Do not modify upstream acme.sh files unless there is no clean alternative.
- Never store private keys, certificate private material, passwords, API tokens, customer information, public/private IP addresses, or production-specific secrets in this repository.
- All changes must be proposed through a pull request and pass the required validation checks before merging into `master`.
- `master` represents the approved version of this fork.
- `update/upstream-review` is automation-owned and must not contain manual commits.

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
enabled;type;name;host;sshUser;certificateProfile;role
```

- `enabled`: `yes` or `no`.
- `type`: `ipo`. Other Avaya product types are outside the current scope.
- `name`: unique label used in logs and state files.
- `host`: DNS name or IP address used for SSH.
- `sshUser`: remote account dedicated to the target type.
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
