# Source of electricity.json (Grafana dashboard "Électricité"). Regenerate after editing:
#   jq -n -f electricity.jq > electricity.json
# Data: recording rules homelab:* on the monitoring host (homelab-nix host/_power-rules.nix).
def ds: {type: "prometheus", uid: "victoriametrics"};
def pos(x; y; w; h): {x: x, y: y, w: w, h: h};
def stat(t; x; color; unit; decimals; expr; desc): {
  type: "stat", title: t, description: desc, datasource: ds, gridPos: pos(x; 0; 6; 5),
  options: {colorMode: "background_solid", graphMode: "area", textMode: "value", justifyMode: "center",
    reduceOptions: {calcs: ["lastNotNull"], values: false}},
  fieldConfig: {defaults: {unit: unit, decimals: decimals, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: [{refId: "A", datasource: ds, expr: expr, instant: true, range: false}]};
def ts(t; x; y; w; unit; expr; legend): {
  type: "timeseries", title: t, datasource: ds, gridPos: pos(x; y; w; 9),
  options: {legend: {displayMode: "list", placement: "bottom"}, tooltip: {mode: "multi"}},
  fieldConfig: {defaults: {unit: unit, min: 0, custom: {lineWidth: 2, fillOpacity: 15, stacking: {mode: "normal"}}}, overrides: []},
  targets: [{refId: "A", datasource: ds, expr: expr, legendFormat: legend, range: true, instant: false}]};

{
  uid: "homelab-electricity", title: "Électricité", tags: ["homelab", "power"], timezone: "browser",
  schemaVersion: 39, editable: false, graphTooltip: 1, refresh: "5m",
  time: {from: "now-7d", to: "now"},
  panels: [
    stat("Coût estimé / mois"; 0; "#ff7a1a"; "currencyEUR"; 2; "sum(homelab:power_cost_eur_month)";
      "Puissance actuelle sur un mois (730 h) au prix fixe du contrat."),
    stat("Puissance estimée"; 6; "#ffcf5a"; "watt"; 1; "sum(homelab:host_power_watts)"; "RAPL (CPU, mémoire) + 5 W pour le reste de la machine."),
    stat("Coût moyen sur 30 jours"; 12; "#18b39b"; "currencyEUR"; 2; "sum(avg_over_time(homelab:power_cost_eur_month[30d]))";
      "Moyenne de l'estimation sur les 30 derniers jours."),
    {type: "text", title: "Une estimation", gridPos: pos(18; 0; 6; 5),
      options: {mode: "markdown", content: "Mesure logicielle, pas un compteur : **RAPL** (CPU et mémoire, lus par le node exporter de nuc1) **+ 5 W** estimés pour le SSD, la carte mère, la carte réseau et les pertes de l'alimentation. Répartition par VM selon leur part du CPU de l'hôte, puis par namespace selon cAdvisor. Prix fixe : 0,25 €/kWh."}},
    ts("Puissance par hôte"; 0; 5; 12; "watt"; "homelab:host_power_watts"; "{{host}}"),
    ts("Puissance par VM"; 12; 5; 12; "watt"; "homelab:vm_power_watts"; "{{node}}"),
    ts("Puissance par namespace"; 0; 14; 24; "watt"; "topk(10, sum by (namespace) (homelab:namespace_power_watts))"; "{{namespace}}")
  ]
}
