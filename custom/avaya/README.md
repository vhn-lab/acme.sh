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
