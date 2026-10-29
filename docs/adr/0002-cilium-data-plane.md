# ADR 0002: Cilium as the only data plane

Status: draft (spike results, 2026-10-29). Finalized in Task 14.

## Context

v2 had Cilium (CNI, kube-proxy replacement, policies, Hubble) next to MetalLB (LoadBalancer
IPs) and k3s's Traefik (Gateway API). Cilium can do both: LB-IPAM with L2 announcements,
and Gateway API through the Envoy it already runs (`cilium-envoy` DaemonSet).

## Spike (homelab-nix branch `spike/cilium-gateway`, Cilium 1.20.2)

Values: `l2announcements.enabled`, `k8sClientRateLimit = { qps = 20; burst = 40; }`,
`gatewayAPI.enabled`. Gateway API CRDs v1.5.1, standard channel (TLSRoute is in it), were
already installed by k3s's `traefik-crd` chart. Cilium accepted them: GatewayClass `cilium`
was `Accepted`, a Gateway became `Programmed`, and an HTTPRoute served an echo backend.

Findings:

1. **Upgrading Cilium with Gateway API turned on left the nodes NotReady.** The operator
   restarted (VM restart) before k3s's Helm job rewrote `cilium-config`. It never created
   the `CiliumEnvoyConfig` CRDs, and the agents waited for them forever ("Still waiting for
   Cilium Operator to register CRDs"). `kubectl -n kube-system rollout restart
   deploy/cilium-operator` fixed it. At cutover, restart the operator after the Cilium
   chart change, before judging the nodes.
2. **Cilium LB-IPAM and MetalLB cannot run side by side.** Once LB-IPAM was active, Cilium
   cleared the status of Traefik's LoadBalancer Services, which MetalLB had assigned
   (`cilium.io/IPAMRequestSatisfied: False, no_pool`). `.240` and `.241` went
   `<pending>`, and the public and internal sites were down for about 2 minutes.
   Restarting the MetalLB controller re-assigned them. Consequence: v3 switches LB-IPAM on
   and MetalLB off in the same cutover, never one before the other. If coexistence is ever
   needed, use Cilium's `defaultLBServiceIPAM: none` together with an explicit
   `loadBalancerClass`.
3. **Pinning the IP**: `Gateway.spec.addresses: [{ type: IPAddress, value: … }]` works.
   The Service `cilium-gateway-<name>` received exactly that IP.
4. **Client IP**: Envoy sets `X-Forwarded-For` to the real TCP source. It was preserved
   through a NodePort on the backend's node (`externalTrafficPolicy: Cluster`). The test
   source was nuc1 itself, because the laptop reached the LAN through Tailscale with nuc1
   masquerading. A test from a real Internet client is still owed at cutover (runbook
   Step 5).
5. **L2 announcements not exercised**. That would have needed a pool, which hits finding
   2, and a client on the LAN itself. They are tested at cutover.
6. **Memory**: `cilium-envoy` uses 15 to 22 Mi per node and `cilium-agent` about 250 Mi
   per node, against an average of about 280 before. Gateway API did not add any
   noticeable agent memory.

## Decision (provisional)

Cilium does LB-IPAM, L2 announcements and Gateway API in v3. Traefik and MetalLB go.
The Gateway API CRDs (v1.5.1, standard) are declared by homelab-nix once `traefik-crd`
is disabled.
