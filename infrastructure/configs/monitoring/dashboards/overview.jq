# Source of overview.json (Grafana dashboard "Vue d'ensemble"). Regenerate after editing:
#   jq -n -f overview.jq > overview.json
# The physical host (node exporter on nuc1, job "node") and the cluster running on it
# (node exporter in each VM, kube-state-metrics, CloudNativePG, Flux), on one page.
def ds: {type: "prometheus", uid: "victoriametrics"};
def pos(x; y; w; h): {x: x, y: y, w: w, h: h};
def row(t; y): {type: "row", title: t, collapsed: false, gridPos: pos(0; y; 24; 1), panels: []};
def stat(t; x; y; color; unit; expr; desc): {
  type: "stat", title: t, description: desc, datasource: ds, gridPos: pos(x; y; 4; 4),
  options: {colorMode: "background_solid", graphMode: "area", textMode: "value", justifyMode: "center",
    reduceOptions: {calcs: ["lastNotNull"], values: false}},
  fieldConfig: {defaults: {unit: unit, decimals: 1, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: [{refId: "A", datasource: ds, expr: expr, instant: true, range: false}]};
def ts(t; x; y; w; unit; targets): {
  type: "timeseries", title: t, datasource: ds, gridPos: pos(x; y; w; 8),
  options: {legend: {displayMode: "list", placement: "bottom"}, tooltip: {mode: "multi"}},
  fieldConfig: {defaults: {unit: unit, min: 0, custom: {lineWidth: 2, fillOpacity: 10}}, overrides: []},
  targets: [targets[] | {refId: .[0], datasource: ds, expr: .[1], legendFormat: .[2], range: true, instant: false}]};
def host: "job=\"node\"";
def vms: "job=\"prometheus-node-exporter\"";

{
  uid: "homelab-overview", title: "Vue d'ensemble", tags: ["homelab"], timezone: "browser",
  schemaVersion: 39, editable: false, graphTooltip: 1, refresh: "1m",
  time: {from: "now-24h", to: "now"},
  panels: [
    row("Hôte physique (nuc1)"; 0),
    stat("CPU"; 0; 1; "#18b3e0"; "percentunit"; "1 - avg(rate(node_cpu_seconds_total{\(host),mode=\"idle\"}[5m]))";
      "Part du CPU occupée, toutes VMs comprises."),
    stat("Mémoire disponible"; 4; 1; "#18b39b"; "bytes"; "node_memory_MemAvailable_bytes{\(host)}";
      "Ce qui reste après les VMs (RAM réservée) et les services de l'hôte."),
    stat("Swap utilisé"; 8; 1; "#ffcf5a"; "bytes"; "node_memory_SwapTotal_bytes{\(host)} - node_memory_SwapFree_bytes{\(host)}"; "zram."),
    stat("Disque (btrfs)"; 12; 1; "#7b2ff7"; "percentunit";
      "max(1 - node_filesystem_avail_bytes{\(host),fstype=\"btrfs\"} / node_filesystem_size_bytes{\(host),fstype=\"btrfs\"})";
      "Une seule pool btrfs : VMs, données NFS, sauvegardes."),
    stat("Température"; 16; 1; "#ff7a1a"; "celsius"; "max(node_hwmon_temp_celsius{\(host)})"; "Capteur le plus chaud."),
    stat("Démarré depuis"; 20; 1; "#18b3e0"; "dtdurations"; "time() - node_boot_time_seconds{\(host)}"; "Dernier redémarrage de nuc1."),
    ts("CPU de l'hôte"; 0; 5; 12; "percentunit"; [
      ["A", "1 - avg(rate(node_cpu_seconds_total{\(host),mode=\"idle\"}[5m]))", "occupé"],
      ["B", "avg(rate(node_cpu_seconds_total{\(host),mode=\"iowait\"}[5m]))", "attente disque"]]),
    ts("Mémoire de l'hôte"; 12; 5; 12; "bytes"; [
      ["A", "node_memory_MemAvailable_bytes{\(host)}", "disponible"],
      ["B", "node_memory_SwapTotal_bytes{\(host)} - node_memory_SwapFree_bytes{\(host)}", "swap"]]),

    row("Cluster"; 13),
    stat("Nœuds prêts"; 0; 14; "#18b39b"; "none";
      "sum(kube_node_status_condition{condition=\"Ready\",status=\"true\"}) or vector(0)"; "Nœuds Kubernetes Ready."),
    stat("Pods en marche"; 4; 14; "#18b3e0"; "none"; "sum(kube_pod_status_phase{phase=\"Running\"})"; ""),
    stat("Redémarrages (24 h)"; 8; 14; "#ff7a1a"; "none";
      "sum(increase(kube_pod_container_status_restarts_total[24h]))"; "Conteneurs redémarrés sur 24 heures."),
    stat("Flux en échec"; 12; 14; "#e2135f"; "none";
      "count(gotk_resource_info{ready=\"False\"}) or vector(0)"; "Kustomizations et HelmReleases non prêtes : flux get all -A."),
    stat("Dernière sauvegarde PostgreSQL"; 16; 14; "#7b2ff7"; "dtdurations";
      "time() - max(cnpg_collector_last_available_backup_timestamp)"; "Sauvegarde de base vers Garage, chaque nuit à 03:00."),
    stat("Certificat le plus proche"; 20; 14; "#ffcf5a"; "dtdurations";
      "min(certmanager_certificate_expiration_timestamp_seconds) - time()"; "cert-manager renouvelle 30 jours avant."),
    ts("Mémoire disponible par nœud"; 0; 18; 12; "bytes"; [
      ["A", "node_memory_MemAvailable_bytes{\(vms)}", "{{node}}"]]),
    ts("CPU par nœud"; 12; 18; 12; "percentunit"; [
      ["A", "1 - avg by (node) (rate(node_cpu_seconds_total{\(vms),mode=\"idle\"}[5m]))", "{{node}}"]]),
    ts("Mémoire par namespace"; 0; 26; 24; "bytes"; [
      ["A", "topk(10, sum by (namespace) (container_memory_working_set_bytes{container!=\"\",container!=\"POD\"}))", "{{namespace}}"]])
  ]
}
