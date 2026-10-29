# ADR 0002: Cilium as the only data plane

Status: accepted (2026-10-29). L2 announcements and the Internet client IP are checked at
cutover.

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

## Decision

Cilium does LB-IPAM, L2 announcements and Gateway API in v3. Traefik and MetalLB go.

- **CRDs**: Gateway API v1.5.1 (standard) is a k3s manifest in homelab-nix
  (`k3s/gateway-api.nix`), next to the controller that serves it. The CRDs k3s's
  `traefik-crd` chart had installed carry `helm.sh/resource-policy: keep`, so disabling
  Traefik leaves them, and the existing objects, in place.
- **Addresses**: one `CiliumLoadBalancerIPPool` `lan` over the router-free range, given as
  `start`/`stop` (`${INGRESS_POOL_START}`/`${INGRESS_POOL_STOP}`); a CIDR would leave out
  its first and last address, and `.240` is the first. One `CiliumL2AnnouncementPolicy`
  restricted to the VMs' LAN interface (`^en`), so pod veths and WireGuard never answer ARP.
- **Gateways**: `public` and `internal`, class `cilium`, in their own namespace `gateway`
  with their certificates. Each pins its address (`spec.addresses`), since the router
  forwards to it. Listeners keep v2's contract (`https`, `holive`, `holive-www`, namespace
  label `gateway-access`), on 443 instead of Traefik's 8443/9443. Plain HTTP listeners
  accept only one route, `https-redirect` (301).
- **Security headers**: Gateway API has no gateway-wide filter, and v2's Traefik entry
  point middleware has no equivalent. Each app's HTTPRoute sets its headers with a
  `ResponseHeaderModifier`: explicit, visible next to the app.
- **Policies**: Gateway traffic reaches backends from Cilium's reserved `ingress` identity.
  Backends allow `fromEntities: [ingress]` instead of a Traefik pod selector.
