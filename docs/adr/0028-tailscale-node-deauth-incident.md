# Tailscale Node De-Authorization Incident (2026-09-03/04)

Postmortem for a Tailscale connectivity outage across six AWS-hosted nodes
(`sap-hana`, `sap-ads`, `java-app`, `node-app`, `react-app`,
`aws-subnet-router` — full inventory in
[INFRASTRUCTURE_REFERENCE.md](../infra/INFRASTRUCTURE_REFERENCE.md)). Logged
as its own ADR rather than a [Parking Lot](0021-parking-lot.md) line since
it's an incident record (what broke, why, how it was fixed), not an open
design question.

## What happened

**sap-hana / sap-ads**: both instances were stopped in AWS, then restarted.
On restart, `tailscaled` came back up as a healthy systemd service, but the
`tailscale0` interface sat `(Unconfigured)` — `systemctl status tailscaled`
showed `Status: "Needs login: https://login.tailscale.com/a/..."`. The node's
session with the tailnet had been invalidated by the stop/start cycle and
needed a fresh interactive login; nothing else (network, DNS, tailnet
billing) was actually wrong.

**java-app / node-app / react-app / aws-subnet-router**: separately, all
four had been manually tagged **Ephemeral** in the Tailscale admin console
the day before. Ephemeral is not a per-device toggle — it's fixed at
registration time (an ephemeral auth key, or `tailscale up --ephemeral`) —
and an ephemeral node is **automatically deleted from the tailnet** shortly
after it disconnects, rather than just going offline. That's a materially
different (and worse) failure mode than the SAP case: instead of a stale
session needing re-login, the node's entire identity is gone and it has to
fully re-register from scratch on its next connection attempt.

## Root cause

Two independent issues, not one:
1. A stop/start cycle alone (SAP case) invalidates the current Tailscale
   session, requiring re-login, but preserves the node's identity/IP.
2. The Ephemeral attribute (other four) turns *any* disconnect (a stop/start,
   a reboot, a scheduled shutdown) into full node deletion, requiring a
   complete re-registration and yielding a **new** Tailscale IP each time.

Given the open TODO in `INFRASTRUCTURE_REFERENCE.md` to rotate the reusable
Tailscale auth key used to originally join these servers, it's worth
checking whether *that key* was created with Ephemeral enabled — if so, any
future server joining via it inherits this same failure mode by default,
independent of anyone manually tagging a device.

## Resolution

**sap-hana / sap-ads** (public IP + `.pem` key available): temporarily
opened port 22 on each instance's security group scoped to a single admin
IP, SSH'd in, ran `tailscale up`, approved via the printed URL, then revoked
the temporary rule immediately after.

**java-app / node-app / react-app** (SSM Session Manager available, already
attached via `TailscaleSSMRole`): fixed out-of-band via
`aws ssm send-command`, independent of Tailscale itself (no risk of losing
the only access path mid-fix) —
```
tailscale logout
tailscale up --ssh   # backgrounded, login URL captured from its log output
```
— then approved each printed URL. All three came back without the Ephemeral
badge, on **new** Tailscale IPs.

**aws-subnet-router** (no SSM, no SSH key pair — `KeyName: None` at launch,
no IAM instance profile): had no independent access path at all. Attempting
to attach `TailscaleSSMRole` (`ec2:AssociateIamInstanceProfile`) and
attempting **EC2 Instance Connect** (`ec2-instance-connect:SendSSHPublicKey`)
both failed — the `tailscale_VarunERP` IAM automation user genuinely lacks
both permissions (not just a Claude Code classifier block; confirmed
`AccessDeniedException`/`UnauthorizedOperation` from AWS itself). Resolved
by temporarily opening port 22 to (a) the admin's own IP and (b) AWS's
published `EC2_INSTANCE_CONNECT` service range for `us-east-1`
(`18.206.107.24/29`, from `ip-ranges.amazonaws.com`) — narrower than
`0.0.0.0/0` — then using the **AWS Console's** browser-based EC2 Instance
Connect (which runs under the admin's own console session, not the scoped
automation user) to run the same `logout`/`up --ssh` sequence. Both
temporary rules were revoked immediately after.

## Follow-on incident: Postgres RDS unreachable after the fix

Confirmed, not hypothetical: after `aws-subnet-router`'s forced rejoin above,
Postgres RDS access broke. Root cause — `tailscale up --ssh` (the command
used to fix the ephemeral/de-auth issue) does not carry forward flags from a
prior session once that session's state has been wiped by `logout`; the
original `--advertise-routes=172.31.0.0/16` was silently dropped, so the
node came back with a **blank** Subnets section, not merely an unapproved
one. Approving section 6's ACL doesn't help if the route was never
re-advertised in the first place.

Fix: re-ran `sudo tailscale up --ssh --advertise-routes=172.31.0.0/16` on
the box (via the same temporary-SG + EC2 Instance Connect access pattern —
attempting `tailscale ssh` instead failed separately with *"tailnet policy
does not permit you to SSH to this node"*, since the ACL policy has no
`ssh` block at all, only the network-layer `acls` shown in section 6),
then approved the now-visible `172.31.0.0/16` route in the admin console.
Postgres connectivity returned immediately after approval.

**Lesson for next time**: any `tailscale up` re-run after a `logout` on a
node serving a specific role (subnet router, exit node, etc.) must restate
**every** non-default flag that role depends on — don't assume flags
persist across a full re-registration.

## Consequences / follow-ups

- **DNS**: `javadev.aiarap.com` / `nodedev.aiarap.com` / `reactdev.aiarap.com`
  (Hostinger A records, section 8 of the infra reference) point at specific
  Tailscale IPs. Since `java-app`/`node-app`/`react-app` re-registered as
  ephemeral nodes get **new** IPs, not their old ones — these DNS records
  need reconciling against whatever addresses they landed on. Not yet
  confirmed done as of this writing.
- **IAM gaps discovered**: `tailscale_VarunERP` lacks
  `ec2:AssociateIamInstanceProfile` and
  `ec2-instance-connect:SendSSHPublicKey`. Not fixed here — the console
  fallback worked — but worth a decision on whether to grant these
  preemptively (faster incident response next time) or keep the automation
  user narrowly scoped and rely on manual console access for this class of
  fix, given `aws-subnet-router` is otherwise the single point of failure
  for reaching the Postgres RDS route (section 2).
- **Check "Disable key expiry"** on `sap-hana`/`sap-ads` — if key expiry is
  enabled, the "Needs login" half of this incident recurs on every future
  stop/start.
- **Un-Ephemeral going forward**: all four affected devices re-registered via
  interactive browser login (not an authkey), so they should already be
  non-ephemeral. Confirm no Ephemeral badge reappears the next time any of
  them restarts.
- Existing TODO (infra reference, section 12) to rotate the reusable
  Tailscale auth key — check its Ephemeral setting specifically while doing
  so, per Root cause above.
- **No `ssh` block in the ACL policy**: `tailscale ssh` is refused tailnet-wide
  ("tailnet policy does not permit you to SSH to this node") since only the
  network-layer `acls` exist (section 6), not a separate `ssh` policy. Not
  fixed here — every fix in this incident used the AWS-console/SG fallback
  instead. Worth deciding whether to add one (e.g. scoping `autogroup:admin`
  SSH access to `tag:infra`/`tag:sap-servers`/`tag:app-servers`) so future
  incidents don't need the SG-reopening dance at all.
