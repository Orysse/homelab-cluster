# ADR 0003: Blocking scanners

Status: accepted (2026-10-29), revised the same day: enforcement moved from a Cilium bouncer
of our own to CrowdSec's firewall bouncer on the hosts.

## Context

The goal is the effect: scanners and bots blocked. CrowdSec as such is not a requirement
(spec, "Blocking scanners"). In v2, a Traefik plugin downloaded at start enforced the bans
in the request path, and per-node agents read Traefik's log files. Traefik is gone in v3
(ADR 0002).

## Detection

Cilium's Gateway can emit Envoy access logs, configured by a `CiliumGatewayClassConfig`
(`spec.telemetry.accessLogs`, format `Text` or `JSON`, Envoy format operators plus
`%CILIUM_GATEWAY_NAMESPACE%` / `%CILIUM_GATEWAY_NAME%`). The GatewayClass references it
through `spec.parametersRef`. The logs go to the stdout of the `cilium-envoy` pods
(kube-system), one pod per node.

Decision: keep **local detection**. The access log is in `Text` format and reproduces
nginx's `combined` format, so CrowdSec's maintained nginx parser and the
`crowdsecurity/http-*` scenarios work unchanged, with no custom parser to maintain:

```
%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT% - - [%START_TIME(%d/%b/%Y:%H:%M:%S %z)%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%" %RESPONSE_CODE% %BYTES_SENT% "%REQ(REFERER)%" "%REQ(USER-AGENT)%"
```

The CrowdSec agents (DaemonSet) read `cilium-envoy`'s container logs on their own node,
labelled `type: nginx`. The OpenTelemetry Collector sends the same lines to VictoriaLogs:
one format serves both, with no duplicate log line. Cost measured in v2 for the agents:
about 38 MB per node, and the whole crowdsec namespace at about 0.03 cores on average
over 7 days, below the 50m-per-node limit set in the plan.

Conditions: `DOWNSTREAM_REMOTE_ADDRESS` must be the visitor's IP (ADR 0002, finding 4,
retested from the Internet at cutover). The exact format string is checked against the
Envoy version shipped with Cilium 1.20 (Task 18).

## Enforcement

**CrowdSec's own firewall bouncer, on the physical hosts** (homelab-nix
`host/crowdsec-bouncer.nix`, packaged in nixpkgs). It pulls the decisions from the LAPI,
exposed on a fixed LAN address (`${LAPI_ADDRESS}`, LoadBalancer, never port-forwarded),
into nftables sets on the `input` and `forward` hooks. nuc1 bridges the VMs onto the LAN
(`br0`), so every packet to the Gateways crosses its kernel; `br_netfilter` hands bridged
packets to those hooks. A banned address is dropped before it reaches a VM.

- nftables sets are hash sets: the community blocklist (tens of thousands of addresses)
  costs the host a few megabytes, and the cluster nothing.
- Decisions carry their expiry into the set: if the LAPI is down, bans stay until they
  expire, and nothing lifts them early.
- Its key is written by a person in two places: sops on the hosts, OpenBao for the LAPI.
- Temporary place, by design: once the NUC7s are the workers, a firewall VM on nuc1 in
  front of the cluster runs the same bouncer with the same configuration.

## Rejected

- **A bouncer of our own writing `CiliumCIDRGroup`s**, dropped by a clusterwide policy on
  Envoy's endpoint. It was written and tested (first version of this ADR), then removed:
  code to maintain alone, for a scale (tens of thousands of CIDRs in every Cilium agent, on
  nodes with about 1 GB free) that was never proven, while the end state is a firewall VM
  running the official bouncer anyway.
- **Cilium's host firewall**: the same scale question, inside the agents.
- **A bouncer in the request path** (Traefik plugin, Envoy ext_authz): every request pays
  for it, and a down LAPI becomes a choice between failing open and failing closed.

## Consequences

- Traffic to Headscale's TLS passthrough listener is not in the access log (ADR 0002), so
  CrowdSec does not see it; it is still dropped for banned addresses.
- The LAPI keeps no volume: after it restarts, decisions come back from the community
  list and from new detections; local bans issued before stay in the hosts' sets until
  their expiry.
