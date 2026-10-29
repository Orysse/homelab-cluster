# ADR 0003: Blocking scanners

Status: draft (2026-10-29). Finalized in Task 18.

## Context

The goal is the effect: scanners and bots blocked. CrowdSec as such is not a requirement
(spec, "Blocking scanners"). In v2, a Traefik plugin downloaded at start enforced the bans
in the request path, and per-node agents read Traefik's log files.

## Enforcement (Task 4): deferred

The scale spike (30 000 CIDRs in `CiliumCIDRGroup`s, choice of the enforcement point) did
not run before the cutover. It would load production Cilium agents, with about 1 GB free
per node and swap in use on kube-3. It also needs a Gateway with an LB IP, which conflicts
with MetalLB (ADR 0002, finding 2). It runs right after the cutover:

- the two enforcement points to compare: a `CiliumClusterwideNetworkPolicy` with
  `ingressDeny.fromCIDRSet[].cidrGroupSelector` on Gateway traffic, and the host firewall;
- start with a trimmed list (local decisions plus one community list), then grow it while
  measuring agent CPU, memory and update latency;
- the bouncer keeps `CHUNK_SIZE` configurable, so no rebuild is needed whatever size is
  chosen.

## Bouncer (Task 5)

No published CrowdSec bouncer writes `CiliumCIDRGroup`s or Cilium policies. The existing
bouncers are the firewall bouncer (iptables/nftables on the host, outside Cilium's policy
model) and in-proxy plugins (Traefik, Caddy, nginx), which put the ban back in the request
path, which is an anti-goal. Decision: write a small controller,
`tools/crowdsec-cilium-bouncer` (Task 8). It streams decisions from LAPI and syncs them
into labelled `CiliumCIDRGroup`s. On error it keeps the existing groups (fail-static).

## Detection source (Task 5)

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
