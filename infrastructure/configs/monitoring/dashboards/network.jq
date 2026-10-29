# Source of network.json (Grafana dashboard "Réseau"). Regenerate after editing:
#   jq -n -f network.jq > network.json
# The Gateways (Cilium's Envoy), the flows Hubble sees, and the scanners CrowdSec bans
# (crowdsec-cilium-bouncer, ADR 0003). The last panel reads the Gateways' access log.
def ds: {type: "prometheus", uid: "victoriametrics"};
def logs: {type: "victoriametrics-logs-datasource", uid: "victorialogs"};
def pos(x; y; w; h): {x: x, y: y, w: w, h: h};
def row(t; y): {type: "row", title: t, collapsed: false, gridPos: pos(0; y; 24; 1), panels: []};
def stat(t; x; y; color; unit; expr; desc): {
  type: "stat", title: t, description: desc, datasource: ds, gridPos: pos(x; y; 6; 4),
  options: {colorMode: "background_solid", graphMode: "area", textMode: "value", justifyMode: "center",
    reduceOptions: {calcs: ["lastNotNull"], values: false}},
  fieldConfig: {defaults: {unit: unit, decimals: 0, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: [{refId: "A", datasource: ds, expr: expr, instant: true, range: false}]};
def ts(t; x; y; w; unit; targets): {
  type: "timeseries", title: t, datasource: ds, gridPos: pos(x; y; w; 8),
  options: {legend: {displayMode: "list", placement: "bottom"}, tooltip: {mode: "multi"}},
  fieldConfig: {defaults: {unit: unit, min: 0, custom: {lineWidth: 2, fillOpacity: 10}}, overrides: []},
  targets: [targets[] | {refId: .[0], datasource: ds, expr: .[1], legendFormat: .[2], range: true, instant: false}]};

{
  uid: "homelab-network", title: "Réseau", tags: ["homelab", "network", "security"], timezone: "browser",
  schemaVersion: 39, editable: false, graphTooltip: 1, refresh: "1m",
  time: {from: "now-24h", to: "now"},
  panels: [
    row("Gateways"; 0),
    stat("Requêtes / s"; 0; 1; "#18b3e0"; "reqps"; "sum(rate(envoy_http_downstream_rq_total[5m]))"; "Toutes les Gateways, tous les nœuds."),
    stat("Erreurs 5xx"; 6; 1; "#e2135f"; "percentunit";
      "sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class=\"5\"}[5m])) / sum(rate(envoy_http_downstream_rq_total[5m]))";
      "Part des réponses en 5xx sur 5 minutes."),
    stat("Connexions ouvertes"; 12; 1; "#18b39b"; "none"; "sum(envoy_http_downstream_cx_active)"; ""),
    stat("Paquets rejetés / s"; 18; 1; "#ff7a1a"; "pps"; "sum(rate(hubble_drop_total[5m]))"; "Par les politiques réseau et le ban."),
    ts("Réponses par classe"; 0; 5; 12; "reqps"; [
      ["A", "sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx[5m]))", "{{envoy_response_code_class}}xx"]]),
    ts("Rejets par raison"; 12; 5; 12; "pps"; [
      ["A", "sum by (reason) (rate(hubble_drop_total[5m]))", "{{reason}}"]]),

    row("Scanners bannis"; 13),
    stat("Adresses bannies"; 0; 14; "#e2135f"; "none"; "max(bouncer_banned_prefixes)"; "Préfixes dans les CiliumCIDRGroups."),
    stat("Groupes"; 6; 14; "#7b2ff7"; "none"; "max(bouncer_groups)"; "CiliumCIDRGroups écrits par le bouncer."),
    stat("Synchros en échec (24 h)"; 12; 14; "#ffcf5a"; "none"; "sum(increase(bouncer_sync_errors_total[24h])) or vector(0)";
      "LAPI injoignable : les bans restent en place."),
    stat("Décisions locales"; 18; 14; "#ff4fb0"; "none"; "sum(cs_active_decisions{origin=\"crowdsec\"}) or vector(0)";
      "Bans décidés à partir des logs de ce cluster (hors liste communautaire)."),
    ts("Adresses bannies"; 0; 18; 12; "none"; [["A", "max(bouncer_banned_prefixes)", "bannies"]]),
    ts("Alertes CrowdSec par scénario"; 12; 18; 12; "none"; [
      ["A", "sum by (reason) (increase(cs_alerts[1h]))", "{{reason}}"]]),

    row("Journal des Gateways"; 26),
    {type: "logs", title: "Dernières requêtes", datasource: logs, gridPos: pos(0; 27; 24; 12),
      options: {showTime: true, wrapLogMessage: false, sortOrder: "Descending", enableLogDetails: true},
      targets: [{refId: "A", datasource: logs, queryType: "instant",
        expr: "{namespace=\"kube-system\", container=\"cilium-envoy\"} \" HTTP/\""}]}
  ]
}
