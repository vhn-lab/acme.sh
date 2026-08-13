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
- `type`: `ipo` or `asbce`.
- `name`: unique label used in logs and state files.
- `host`: DNS name or IP address used for SSH.
- `sshUser`: remote account dedicated to the target type.
- `certificateProfile`: groups targets that receive the same certificate.
- `role`: `standalone`, `primary`, or `secondary`.

This model supports one or two IP Office systems and zero, one, or two ASBCE
systems without duplicating deployment scripts. It also allows a future setup to
use separate certificates by assigning different certificate profiles.

The example lists the largest supported topology. Unused targets are removed or
set to `enabled=no` in the production copy.
