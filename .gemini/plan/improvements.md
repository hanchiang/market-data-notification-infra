# Improvement Plan for Market Data Notification Infrastructure

## 1. Refactor Ansible Playbooks
The current Ansible playbook `instances/ansible/playbooks/nginx-https.yml` relies heavily on the `shell` module for tasks that should use native Ansible modules. This improves readability, idempotency, and maintainability.

- [ ] **Use `apt` module:** Replace `shell: apt -y install ...` with the standard `apt` module.
- [ ] **Use `template` module:** Move the embedded Nginx configuration HEREDOCs into separate `.j2` template files and use the `template` module to deploy them.
- [ ] **Use `systemd`/`service` module:** Replace `systemctl` shell commands with the `service` module for Nginx reloading/restarting.
- [ ] **Clean up Certbot Logic:** Simplify the complex shell logic for Certbot or use a community role/collection if appropriate, but primarily structure the shell script better if a module isn't a direct fit.

## 2. Eliminate Hardcoded Values
Hardcoded values reduce flexibility and make the scripts brittle to environment changes.

- [ ] **Route53 Hosted Zone ID:** The ID `Z036374065L40GHHCTH5` is hardcoded in `instances/scripts/route53/update-ec2-route53.sh`. This should be passed as an argument or environment variable.
- [ ] **Domain Names:** `api.marketdata.yaphc.com` is hardcoded in `start.sh` and `stop.sh`. Ensure this is consistently passed from the `DOMAINS` variable or arguments.

## 3. Enhance Script Robustness
The bash scripts perform critical orchestration and can be made more robust.

- [ ] **Improve DNS Waiting:** Refactor `instances/scripts/helper/wait_for_dns_propagation.sh` to use `dig +short` or `host` instead of parsing `nslookup` output, which is less reliable across different systems/versions.
- [ ] **AWS CLI Waiters:** Where applicable, investigate using `aws ec2 wait` commands instead of custom `while` loops for instance state checks (though the custom loop provides decent feedback, native waiters are standard).

## 4. Security & Configuration
- [ ] **SSH Access:** Review `instances/main.tf` security group settings. Access to port 22 is currently open to `0.0.0.0/0`. Consider parameterizing this to allow restricting to a specific IP range if needed.

## 5. Documentation
- [ ] **Update README:** Ensure any changes in variable handling (like the Route53 Zone ID) are reflected in the usage documentation.
