# Build Image

## Working Directory
- Run Packer from `images/`.

## Required Inputs
- Copy `variables.auto.pkrvars.hcl.example` to `variables.auto.pkrvars.hcl` and fill in the inputs used by `image.pkr.hcl`.
- `variables.auto.pkrvars.hcl` is local-only and ignored by Git through the repo-wide `*.pkrvars.hcl` rule.
- The practically relevant inputs today are:
  - `region`
  - `ssh_public_key_src_path`
  - `ssh_public_key_dest_path`
  - `admin_email`
  - `letsencrypt_src_path`
  - `letsencrypt_dest_path`

## Notes
- The build currently copies a local Let's Encrypt artifact into the image build and unpacks it during nginx installation.
- That path is legacy compatibility state, not the preferred long-term TLS recovery design.
- Do not deepen reliance on the image-baked Let's Encrypt artifact while the runtime backup and restore path is being introduced.

## Build Command
```bash
cp variables.auto.pkrvars.hcl.example variables.auto.pkrvars.hcl
packer build -machine-readable -var-file=variables.auto.pkrvars.hcl image.pkr.hcl | tee build.log
```
