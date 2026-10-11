# Source of umami.json (Grafana dashboard "Sites (Umami)"). Regenerate after editing:
#   jq -n -f umami.jq > umami.json
# Colours: the vitrine's palette.
def magenta: "#e2135f"; def orange: "#ff7a1a"; def teal: "#18b39b"; def violet: "#7b2ff7";
def blue: "#18b3e0"; def gold: "#ffcf5a"; def pink: "#ff4fb0";
def ds: {type: "grafana-postgresql-datasource", uid: "umami"};
def F: "website_id::text IN ($website)";
def TF: "$__timeFilter(created_at)";
def ev: "FROM website_event WHERE \(TF) AND \(F)";
def pv: "FROM website_event WHERE event_type = 1 AND \(TF) AND \(F)";
def flag(c): "CASE WHEN \(c) ~ '^[A-Z]{2}$' THEN chr(127397 + ascii(substr(\(c), 1, 1))) || chr(127397 + ascii(substr(\(c), 2, 1))) ELSE '·' END";
def q(sql; fmt): [{refId: "A", datasource: ds, format: fmt, rawQuery: true, editorMode: "code", rawSql: sql}];
def pos(x; y; w; h): {x: x, y: y, w: w, h: h};
def row(t; y): {type: "row", title: t, collapsed: false, gridPos: pos(0; y; 24; 1), panels: []};
def stat(t; x; y; color; unit; dec; sql): {
  type: "stat", title: t, datasource: ds, gridPos: pos(x; y; 4; 4),
  options: {colorMode: "background_solid", graphMode: "none", textMode: "value", justifyMode: "center",
    reduceOptions: {calcs: ["lastNotNull"], values: false}},
  fieldConfig: {defaults: {unit: unit, decimals: dec, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: q(sql; "table")};
def bars(t; x; y; w; h; color; sql): {
  type: "bargauge", title: t, datasource: ds, gridPos: pos(x; y; w; h),
  options: {orientation: "horizontal", displayMode: "gradient", valueMode: "color", namePlacement: "left",
    showUnfilled: true, sizing: "manual", minVizHeight: 18, maxVizHeight: 22,
    reduceOptions: {values: true, calcs: [], limit: 15}},
  fieldConfig: {defaults: {min: 0, color: {mode: "fixed", fixedColor: color}}, overrides: []},
  targets: q(sql; "table")};
def donut(t; x; y; sql): {
  type: "piechart", title: t, datasource: ds, gridPos: pos(x; y; 6; 8),
  options: {pieType: "donut", displayLabels: ["percent"], legend: {displayMode: "table", placement: "right", values: ["value"]},
    reduceOptions: {values: true, calcs: []}},
  fieldConfig: {defaults: {color: {mode: "palette-classic"}}, overrides: []},
  targets: q(sql; "table")};
def visits: "SELECT visit_id, session_id, website_id, min(created_at) AS debut, max(created_at) AS fin, count(*) FILTER (WHERE event_type = 1) AS pages, string_agg(url_path, ' → ' ORDER BY created_at) FILTER (WHERE event_type = 1) AS parcours \(ev) GROUP BY 1, 2, 3";

{
  uid: "umami", title: "Sites (Umami)", tags: ["umami", "analytics"], timezone: "browser",
  schemaVersion: 39, editable: false, graphTooltip: 1, refresh: "5m",
  time: {from: "now-7d", to: "now"},
  templating: {list: [{
    name: "website", label: "Site", type: "query", datasource: ds, refresh: 1, multi: true, includeAll: true,
    query: "SELECT name AS __text, website_id::text AS __value FROM website WHERE deleted_at IS NULL ORDER BY name",
    current: {selected: true, text: ["All"], value: ["$__all"]}}]},
  panels: [
    row("Audience"; 0),
    stat("Visiteurs"; 0; 1; magenta; "none"; 0; "SELECT count(DISTINCT session_id) \(ev)"),
    stat("Visites"; 4; 1; orange; "none"; 0; "SELECT count(DISTINCT visit_id) \(ev)"),
    stat("Pages vues"; 8; 1; teal; "none"; 0; "SELECT count(*) \(pv)"),
    stat("Pages par visite"; 12; 1; violet; "none"; 1; "SELECT count(*) FILTER (WHERE event_type = 1)::float / NULLIF(count(DISTINCT visit_id), 0) \(ev)"),
    stat("Durée moyenne"; 16; 1; blue; "s"; 0; "SELECT avg(extract(epoch FROM fin - debut)) FROM (\(visits)) v"),
    stat("Rebond"; 20; 1; pink; "percentunit"; 0; "SELECT avg((pages <= 1)::int) FROM (\(visits)) v"),
    {type: "timeseries", title: "Trafic", datasource: ds, gridPos: pos(0; 5; 24; 8),
      options: {legend: {displayMode: "list", placement: "bottom"}, tooltip: {mode: "multi"}},
      fieldConfig: {defaults: {custom: {drawStyle: "bars", fillOpacity: 90, gradientMode: "hue", lineWidth: 0, barAlignment: 0}},
        overrides: [
          {matcher: {id: "byName", options: "pages vues"}, properties: [{id: "color", value: {mode: "fixed", fixedColor: teal}}]},
          {matcher: {id: "byName", options: "visiteurs"}, properties: [
            {id: "color", value: {mode: "fixed", fixedColor: magenta}}, {id: "custom.drawStyle", value: "line"},
            {id: "custom.lineWidth", value: 3}, {id: "custom.fillOpacity", value: 15}, {id: "custom.lineInterpolation", value: "smooth"}]}]},
      targets: q("SELECT $__timeGroupAlias(created_at, $__interval), count(*) FILTER (WHERE event_type = 1) AS \"pages vues\", count(DISTINCT session_id) AS visiteurs \(ev) GROUP BY 1 ORDER BY 1"; "time_series")},

    row("Géographie"; 13),
    {type: "geomap", title: "Carte", datasource: ds, gridPos: pos(0; 14; 14; 12),
      options: {view: {id: "zero", lat: 35, lon: 10, zoom: 1.6}, controls: {showZoom: true, mouseWheelZoom: false, showAttribution: false},
        basemap: {type: "carto", name: "Fond", config: {theme: "dark", showLabels: false}},
        layers: [{type: "markers", name: "Visiteurs", tooltip: true,
          location: {mode: "lookup", lookup: "pays", gazetteer: "public/gazetteer/countries.json"},
          config: {showLegend: false, style: {
            size: {field: "visiteurs", min: 8, max: 40, fixed: 10},
            color: {fixed: magenta}, opacity: 0.75,
            symbol: {mode: "fixed", fixed: "img/icons/marker/circle.svg"},
            text: {mode: "field", field: "visiteurs", fixed: ""},
            textConfig: {fontSize: 12, textAlign: "center", textBaseline: "middle", offsetX: 0, offsetY: 0}}}}],
        tooltip: {mode: "details"}},
      fieldConfig: {defaults: {}, overrides: []},
      targets: q("SELECT country AS pays, count(*) AS visiteurs FROM session WHERE country IS NOT NULL AND session_id IN (SELECT session_id \(ev)) GROUP BY 1"; "table")},
    bars("Pays"; 14; 14; 5; 12; magenta; "SELECT \(flag("country")) || ' ' || coalesce(country, '?') AS pays, count(*) AS visiteurs FROM session WHERE session_id IN (SELECT session_id \(ev)) GROUP BY country ORDER BY 2 DESC LIMIT 15"),
    bars("Villes"; 19; 14; 5; 12; violet; "SELECT \(flag("country")) || ' ' || coalesce(city, '?') AS ville, count(*) AS visiteurs FROM session WHERE session_id IN (SELECT session_id \(ev)) GROUP BY country, city ORDER BY 2 DESC LIMIT 15"),

    row("Contenu"; 26),
    bars("Pages"; 0; 27; 12; 10; teal; "SELECT url_path AS page, count(*) AS vues \(pv) GROUP BY 1 ORDER BY 2 DESC LIMIT 15"),
    bars("Référents"; 12; 27; 12; 10; orange; "SELECT referrer_domain AS site, count(DISTINCT visit_id) AS visites \(ev) AND referrer_domain IS NOT NULL AND referrer_domain <> '' AND referrer_domain <> hostname GROUP BY 1 ORDER BY 2 DESC LIMIT 15"),

    row("Sessions"; 37),
    {type: "table", title: "Dernières visites", datasource: ds, gridPos: pos(0; 38; 24; 12),
      options: {showHeader: true, cellHeight: "sm", footer: {show: false}},
      fieldConfig: {defaults: {custom: {align: "auto", cellOptions: {type: "auto"}}}, overrides: [
        {matcher: {id: "byName", options: "durée"}, properties: [{id: "unit", value: "s"}, {id: "custom.width", value: 90}]},
        {matcher: {id: "byName", options: "pages"}, properties: [{id: "custom.width", value: 70},
          {id: "custom.cellOptions", value: {type: "color-background", mode: "gradient"}},
          {id: "color", value: {mode: "continuous-YlRd"}}]},
        {matcher: {id: "byName", options: "début"}, properties: [{id: "custom.width", value: 160}, {id: "unit", value: "dateTimeAsLocal"}]},
        {matcher: {id: "byName", options: "site"}, properties: [{id: "custom.width", value: 90}]},
        {matcher: {id: "byName", options: "parcours"}, properties: [{id: "custom.minWidth", value: 400}]}]},
      targets: q("SELECT v.debut AS \"début\", w.name AS site, \(flag("s.country")) || ' ' || coalesce(s.city, s.country, '?') AS lieu, concat_ws(' · ', s.device, s.os, s.browser) AS appareil, v.pages, extract(epoch FROM v.fin - v.debut) AS \"durée\", left(v.parcours, 400) AS parcours FROM (\(visits)) v JOIN session s USING (session_id) JOIN website w ON w.website_id = v.website_id ORDER BY v.debut DESC LIMIT 100"; "table")},
    bars("Parcours fréquents"; 0; 50; 12; 10; gold; "SELECT de || '  →  ' || vers AS parcours, count(*) AS fois FROM (SELECT url_path AS vers, lag(url_path) OVER (PARTITION BY visit_id ORDER BY created_at) AS de \(pv)) t WHERE de IS NOT NULL AND de <> vers GROUP BY 1 ORDER BY 2 DESC LIMIT 15"),
    bars("Pages d'entrée"; 12; 50; 6; 10; blue; "SELECT url_path AS page, count(*) AS visites FROM (SELECT DISTINCT ON (visit_id) visit_id, url_path \(pv) ORDER BY visit_id, created_at) t GROUP BY 1 ORDER BY 2 DESC LIMIT 10"),
    bars("Pages de sortie"; 18; 50; 6; 10; pink; "SELECT url_path AS page, count(*) AS visites FROM (SELECT DISTINCT ON (visit_id) visit_id, url_path \(pv) ORDER BY visit_id, created_at DESC) t GROUP BY 1 ORDER BY 2 DESC LIMIT 10"),

    row("Technique"; 60),
    donut("Navigateurs"; 0; 61; "SELECT coalesce(browser, '?') AS navigateur, count(*) AS visiteurs FROM session WHERE session_id IN (SELECT session_id \(ev)) GROUP BY 1 ORDER BY 2 DESC LIMIT 8"),
    donut("Systèmes"; 6; 61; "SELECT coalesce(os, '?') AS os, count(*) AS visiteurs FROM session WHERE session_id IN (SELECT session_id \(ev)) GROUP BY 1 ORDER BY 2 DESC LIMIT 8"),
    donut("Appareils"; 12; 61; "SELECT coalesce(device, '?') AS appareil, count(*) AS visiteurs FROM session WHERE session_id IN (SELECT session_id \(ev)) GROUP BY 1 ORDER BY 2 DESC"),
    donut("Langues"; 18; 61; "SELECT coalesce(split_part(language, '-', 1), '?') AS langue, count(*) AS visiteurs FROM session WHERE session_id IN (SELECT session_id \(ev)) GROUP BY 1 ORDER BY 2 DESC LIMIT 8")
  ] | to_entries | map(.value + {id: (.key + 1)})
}
