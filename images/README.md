# Build image
`packer build -machine-readable -var-file=variables.auto.pkrvars.hcl image.pkr.hcl | tee build.log`