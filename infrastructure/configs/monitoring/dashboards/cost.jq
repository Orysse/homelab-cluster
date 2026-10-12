# Source of cost.json (Grafana dashboard "Coût et conso"). Regenerate after editing:
#   jq -n -f cost.jq > cost.json
# Power: nuc1's RAPL "psys" counter (homelab-nix monitoring.nix) divided by the supply's
# efficiency = an estimate of the power at the wall. Prices: the same as OpenCost
# (apps/opencost/opencost.yaml), as hidden constants below.
def ds: {type: "prometheus", uid: "victoriametrics"};
def pos(x; y; w; h): {x: x, y: y, w: w, h: h};
def q(expr; legend): {refId: legend, datasource: ds, expr: expr, legendFormat: legend, instant: false, range: true};
def qi(expr): {refId: "A", datasource: ds, expr: expr, instant: true, range: false};
def row(t; y): {type: "row", title: t, collapsed: false, gridPos: pos(0; y; 24; 1), panels: []};
def stat(t; x; y; w; color; unit; dec; expr; desc): {
  type: "stat", title: t, description: desc, datasource: ds, gridPos: pos(x; y; w; 4),
  options: {colorMode: "background_solid", graphMode: "area", textMode: "value", justifyMode: "center",
    reduceOptions: {calcs: ["lastNotNull"], values: false}},
  fieldConfig: {defaults: {unit: unit, decimals: dec, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: [qi(expr)]};
def const(n; v; lbl): {name: n, label: lbl, type: "constant", hide: 2, query: v, current: {text: v, value: v}};

# Power at the wall (W), and its average over a window.
def wall: "rate(node_rapl_psys_joules_total{host=\"nuc1\"}[5m]) / $rendement";
def wallavg(w): "avg_over_time((rate(node_rapl_psys_joules_total{host=\"nuc1\"}[5m]))[\(w):5m]) / $rendement";
# OpenCost: what each namespace's CPU and RAM allocations cost per hour (EUR).
def nscost: "sum by (exported_namespace) (container_cpu_allocation * on (exported_node) group_left () max by (exported_node) (node_cpu_hourly_cost) + container_memory_allocation_bytes / 1073741824 * on (exported_node) group_left () max by (exported_node) (node_ram_hourly_cost))";

{
  uid: "homelab-cost", title: "Coût et conso", tags: ["homelab", "cost"], timezone: "browser",
  schemaVersion: 39, editable: false, graphTooltip: 1, refresh: "1m",
  time: {from: "now-24h", to: "now"},
  templating: {list: [
    const("prix_kwh"; "0.2001"; "EUR/kWh (EDF Tarif Bleu)"),
    const("rendement"; "0.85"; "Rendement de l'alimentation"),
    const("ovh_an"; "27.58"; "OVH, EUR/an (domaine + mail)")]},
  panels: [
    row("nuc1 à la prise (estimation)"; 0),
    stat("Puissance"; 0; 1; 4; "#ff7a1a"; "watt"; 1; wall; "RAPL psys / rendement de l'alimentation (~85 %)."),
    stat("Moyenne 24 h"; 4; 1; 4; "#e2135f"; "watt"; 1; wallavg("24h"); "Puissance moyenne sur les dernières 24 heures."),
    stat("Énergie 30 j"; 8; 1; 4; "#18b39b"; "kwatth"; 1;
      "increase(node_rapl_psys_joules_total{host=\"nuc1\"}[30d]) / $rendement / 3600000";
      "Énergie consommée sur 30 jours (ou depuis le début de la mesure)."),
    stat("Électricité / mois"; 12; 1; 4; "#7b2ff7"; "currencyEUR"; 2;
      "\(wallavg("7d")) / 1000 * 730 * $prix_kwh";
      "Projection sur un mois à la puissance moyenne des 7 derniers jours."),
    stat("Total / an"; 16; 1; 4; "#18b3e0"; "currencyEUR"; 0;
      "\(wallavg("7d")) / 1000 * 8760 * $prix_kwh + $ovh_an";
      "Électricité projetée sur un an (moyenne 7 j) + OVH (domaine et mail). Sans amortissement du matériel."),
    stat("Cluster / mois (OpenCost)"; 20; 1; 4; "#ffcf5a"; "currencyEUR"; 2;
      "sum(max by (exported_node) (node_total_hourly_cost)) * 730";
      "Coût horaire des trois nœuds selon OpenCost (électricité + OVH répartis sur CPU et RAM), sur un mois."),
    {type: "timeseries", title: "Puissance", datasource: ds, gridPos: pos(0; 5; 24; 9),
      options: {legend: {displayMode: "list", placement: "bottom"}, tooltip: {mode: "multi"}},
      fieldConfig: {defaults: {unit: "watt", min: 0, custom: {lineWidth: 2, fillOpacity: 12, gradientMode: "opacity", lineInterpolation: "smooth"}},
        overrides: [
          {matcher: {id: "byName", options: "à la prise (estimée)"}, properties: [{id: "color", value: {mode: "fixed", fixedColor: "#ff7a1a"}}]},
          {matcher: {id: "byName", options: "CPU (package)"}, properties: [{id: "color", value: {mode: "fixed", fixedColor: "#7b2ff7"}}]}]},
      targets: [
        q(wall; "à la prise (estimée)"),
        q("rate(node_rapl_package_joules_total{host=\"nuc1\"}[5m])"; "CPU (package)")]},
    row("Répartition par namespace (OpenCost)"; 14),
    {type: "piechart", title: "Coût mensuel par namespace", datasource: ds, gridPos: pos(0; 15; 10; 10),
      options: {pieType: "donut", displayLabels: ["percent"], legend: {displayMode: "table", placement: "right", values: ["value"], sortBy: "Value", sortDesc: true},
        reduceOptions: {values: false, calcs: ["lastNotNull"]}},
      fieldConfig: {defaults: {unit: "currencyEUR", decimals: 2, color: {mode: "palette-classic"}}, overrides: []},
      targets: [{refId: "A", datasource: ds, expr: "\(nscost) * 730", legendFormat: "{{exported_namespace}}", instant: true, range: false}]},
    {type: "timeseries", title: "Coût horaire par namespace", datasource: ds, gridPos: pos(10; 15; 14; 10),
      options: {legend: {displayMode: "table", placement: "right", calcs: ["mean"], sortBy: "Mean", sortDesc: true}, tooltip: {mode: "multi", sort: "desc"}},
      fieldConfig: {defaults: {unit: "currencyEUR", decimals: 4, min: 0, custom: {stacking: {mode: "normal"}, fillOpacity: 60, lineWidth: 1}}, overrides: []},
      targets: [q(nscost; "{{exported_namespace}}")]}
  ]
}
