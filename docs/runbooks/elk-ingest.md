# Runbook: ingest and re-ingest logs into ELK (Rush2)

Raw rsyslog files (Windows events as XML, Stormshield SNS, BIND, nginx, Kea) go through
Logstash on a workstation to `elk.${DOMAIN}`, parsed to ECS, one data stream per source and
site: `logs-<dataset>-<site>` (`logs-windows-fr`, `logs-sns-de`, ...). `dataset` is one of
`windows sns nginx dns dhcp unparsed`; `site` is the folder under `logs/` (`fr`, `de`).

Why client side: the ingest route (`apps/elk/elasticsearch.yaml`) passes only `/` and `/_bulk`,
and the Kibana account (`kibana-users`) has no cluster privilege. No pipeline or template is
needed in the cluster; the parsing lives in `elk-ingest.pipeline.conf` (next to this file).

Logstash reads the server version with `GET /` at start; `ingest` (role `logs-writer`) needs
the cluster privilege `monitor` for it, which `elk-setup` grants. Without it, `GET /` returns 403.

Status of the pipeline: written, **not yet run**. Dry-run first (below) and delete this line
once the tags and timestamps check out.

## Ingest

`ES_URL` needs the port: `https://elk.<DOMAIN>:443` (without it the plugin adds `:9200`). The
Logstash output checks the license with `GET /_license` when it connects and treats a 404 as an
incompatible server (loop on "Could not connect to a compatible version"); no client setting
avoids it (`ilm_enabled` and `manage_template` are refused with `data_stream => true`), so the
route passes `GET /_license`. Rootless Podman: add `--userns=keep-id:uid=1000,gid=1000`, the
files extracted from the tar are 0640.

Layout: `logs/<site>/*.log` on the workstation. Logstash 9.5.6 (same version as the stack).

```sh
# the ingest password never goes in a file or in the shell history
export ES_PASSWORD=$(kubectl -n elk get secret keys -o jsonpath='{.data.INGEST_PASSWORD}' | base64 -d)
export ES_URL=https://elk.<DOMAIN>

# 1. dry run: prints events instead of sending; stop it with Ctrl-C
docker run --rm -e DRY_RUN=1 -v "$PWD/logs:/logs:ro" \
  -v "$PWD/elk-ingest.pipeline.conf:/usr/share/logstash/pipeline/logstash.conf:ro" \
  docker.elastic.co/logstash/logstash:9.5.6

# 2. real run, once
docker run --rm -e ES_URL -e ES_PASSWORD -v "$PWD/logs:/logs:ro" \
  -v "$PWD/elk-ingest.pipeline.conf:/usr/share/logstash/pipeline/logstash.conf:ro" \
  docker.elastic.co/logstash/logstash:9.5.6
```

Check in the dry run: no `_unparsed`, `_win_unparsed`, `_nginx_unparsed` or `_dns_unparsed` tag
on a normal line; `sns.time` is one value (`2026-11-11 14:36:07`); an nginx line logged
`14:36:01 +0200` has `@timestamp` 12:36:01Z (its syslog header is local time labelled UTC).

## Re-ingest

A second run **duplicates** every event (random `_id`), and `ingest` cannot delete. So wipe
the affected streams first, as `elastic`, from inside the Elasticsearch pod: `ELASTIC_PASSWORD`
is already in its environment, so no password is read or typed.

```sh
# what exists
kubectl -n elk exec deploy/elasticsearch -- sh -c \
  'curl -fsS -u "elastic:$ELASTIC_PASSWORD" "localhost:9200/_data_stream/logs-*?filter_path=data_streams.name"'

# delete only what you will re-ingest (names, no wildcard; add the raw v0 pair if still there)
kubectl -n elk exec deploy/elasticsearch -- sh -c \
  'curl -fsS -u "elastic:$ELASTIC_PASSWORD" -X DELETE "localhost:9200/_data_stream/logs-windows-fr,logs-sns-fr,logs-nginx-fr,logs-dns-fr,logs-dhcp-fr,logs-unparsed-fr"'
```

Then run step 2 again. Kibana data views, dashboards and saved searches are saved objects and
survive the wipe. A pipeline fix only needs the streams of the source it touched wiped.

Rejected documents (mapping errors such as a non-IP in `source.ip`) go to the failure store,
which `kibana-users` cannot read. As `elastic`, same `kubectl exec`:
`curl -u "elastic:$ELASTIC_PASSWORD" "localhost:9200/logs-windows-fr::failures/_search?size=3"`.
Logstash also logs `mapper_parsing_exception` for them.

## Known limits

- Windows files are read as UTF-8; if accents come out garbled they are CP1252 and need their
  own `file` input with `charset => "CP1252"`.
- Windows `@timestamp` comes from `<timereported>`, assumed UTC (it matches the rsyslog
  header). Check with a min/max per `host.name` before trusting cross-source timelines.
- `logs-*` data streams follow the `logs` ILM policy (no delete); the 14-day retention in
  `elk-setup` is the data stream lifecycle and does not apply to them.
