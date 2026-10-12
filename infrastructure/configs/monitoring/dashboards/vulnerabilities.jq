# Source of vulnerabilities.json (Grafana dashboard "Vulnérabilités"). Regenerate after editing:
#   jq -n -f vulnerabilities.jq > vulnerabilities.json
# Data: the daily Trivy scan of the running images, on the monitoring host (homelab-nix
# trivy.nix). Details of an image's vulnerabilities: on that host (docs there).
def ds: {type: "prometheus", uid: "victoriametrics"};
def pos(x; y; w; h): {x: x, y: y, w: w, h: h};
def qi(id; expr): {refId: id, datasource: ds, expr: expr, instant: true, range: false, format: "table"};
def row(t; y): {type: "row", title: t, collapsed: false, gridPos: pos(0; y; 24; 1), panels: []};
def stat(t; x; color; unit; expr; desc): {
  type: "stat", title: t, description: desc, datasource: ds, gridPos: pos(x; 1; 4; 4),
  options: {colorMode: "background_solid", graphMode: "none", textMode: "value", justifyMode: "center",
    reduceOptions: {calcs: ["lastNotNull"], values: false}},
  fieldConfig: {defaults: {unit: unit, decimals: 0, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: [{refId: "A", datasource: ds, expr: expr, instant: true, range: false}]};
def v(sev; fixable): "max by (image) (trivy_image_vulnerabilities\(if fixable then "_fixable" else "" end){severity=\"\(sev)\"})";
def col(name; color): {matcher: {id: "byName", options: name}, properties: [
  {id: "custom.cellOptions", value: {type: "color-text"}}, {id: "color", value: {mode: "fixed", fixedColor: color}}]};

{
  uid: "homelab-vulnerabilities", title: "Vulnérabilités", tags: ["homelab", "security", "trivy"], timezone: "browser",
  schemaVersion: 39, editable: false, graphTooltip: 1, refresh: "5m",
  time: {from: "now-30d", to: "now"},
  panels: [
    row("Images en cours d'exécution (scan Trivy quotidien)"; 0),
    stat("Critiques corrigeables"; 0; "#e2135f"; "none"; "sum(\(v("CRITICAL"; true)))";
      "CVE critiques pour lesquelles une version corrigée existe : mettre à jour l'image."),
    stat("Critiques"; 4; "#ff4fb0"; "none"; "sum(\(v("CRITICAL"; false)))"; "Toutes les CVE critiques, corrigées en amont ou non."),
    stat("Hautes corrigeables"; 8; "#ff7a1a"; "none"; "sum(\(v("HIGH"; true)))"; "CVE hautes avec une version corrigée."),
    stat("Images scannées"; 12; "#18b39b"; "none"; "count(max by (image) (trivy_image_scan_success))"; "Images distinctes en cours d'exécution dans le cluster."),
    stat("Scans en échec"; 16; "#7b2ff7"; "none"; "count(max by (image) (trivy_image_scan_success) == 0) or vector(0)";
      "Registre injoignable, limite de requêtes ou image non supportée : journalctl -u trivy-scan sur nuc1."),
    stat("Dernier scan"; 20; "#18b3e0"; "dtdurations"; "time() - max(trivy_last_run_timestamp_seconds)"; "Le scan tourne chaque nuit vers 04:30."),
    {type: "table", title: "Par image", datasource: ds, gridPos: pos(0; 5; 24; 14),
      options: {showHeader: true, sortBy: [{displayName: "Critiques corrigeables", desc: true}], cellHeight: "sm"},
      fieldConfig: {defaults: {custom: {align: "auto", filterable: true}}, overrides: [
        col("Critiques corrigeables"; "#e2135f"), col("Critiques"; "#ff4fb0"),
        col("Hautes corrigeables"; "#ff7a1a"), col("Hautes"; "#ffcf5a"),
        {matcher: {id: "byName", options: "image"}, properties: [{id: "custom.width", value: 520}]}]},
      targets: [
        qi("A"; v("CRITICAL"; true)), qi("B"; v("CRITICAL"; false)),
        qi("C"; v("HIGH"; true)), qi("D"; v("HIGH"; false)), qi("E"; v("MEDIUM"; false))],
      transformations: [
        {id: "merge", options: {}},
        {id: "organize", options: {
          excludeByName: {Time: true},
          renameByName: {"Value #A": "Critiques corrigeables", "Value #B": "Critiques",
            "Value #C": "Hautes corrigeables", "Value #D": "Hautes", "Value #E": "Moyennes"},
          indexByName: {image: 0, "Value #A": 1, "Value #B": 2, "Value #C": 3, "Value #D": 4, "Value #E": 5}}}]},
    row("Évolution"; 19),
    {type: "timeseries", title: "Vulnérabilités corrigeables, par gravité", datasource: ds, gridPos: pos(0; 20; 24; 9),
      options: {legend: {displayMode: "list", placement: "bottom"}, tooltip: {mode: "multi"}},
      fieldConfig: {defaults: {min: 0, custom: {lineWidth: 2, fillOpacity: 10, lineInterpolation: "stepAfter"}}, overrides: [
        {matcher: {id: "byName", options: "CRITICAL"}, properties: [{id: "color", value: {mode: "fixed", fixedColor: "#e2135f"}}]},
        {matcher: {id: "byName", options: "HIGH"}, properties: [{id: "color", value: {mode: "fixed", fixedColor: "#ff7a1a"}}]},
        {matcher: {id: "byName", options: "MEDIUM"}, properties: [{id: "color", value: {mode: "fixed", fixedColor: "#ffcf5a"}}]}]},
      targets: [{refId: "A", datasource: ds, legendFormat: "{{severity}}", range: true, instant: false,
        expr: "sum by (severity) (max by (image, severity) (trivy_image_vulnerabilities_fixable{severity=~\"CRITICAL|HIGH|MEDIUM\"}))"}]}
  ]
}
