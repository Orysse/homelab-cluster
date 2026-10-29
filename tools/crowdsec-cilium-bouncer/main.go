// crowdsec-cilium-bouncer streams ban decisions from a CrowdSec LAPI and
// writes them into labelled CiliumCIDRGroups, which a Cilium network policy
// selects to drop the traffic. See README.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	csbouncer "github.com/crowdsecurity/go-cs-bouncer"
	"github.com/crowdsecurity/crowdsec/pkg/models"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/config"
)

// decisions holds the active bans, keyed by prefix, as the LAPI stream
// reports them. Until the first answer it does not know the set and refuses
// to give one, so a start without LAPI never empties the groups.
type decisions struct {
	mu     sync.Mutex
	banned map[netip.Prefix]struct{}
	synced bool
}

func (d *decisions) apply(resp *models.DecisionsStreamResponse) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, dec := range resp.Deleted {
		if p, ok := banPrefix(dec); ok {
			delete(d.banned, p)
		}
	}
	for _, dec := range resp.New {
		if p, ok := banPrefix(dec); ok {
			d.banned[p] = struct{}{}
		}
	}
	d.synced = true
}

func (d *decisions) Prefixes() ([]netip.Prefix, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.synced {
		return nil, errors.New("no answer from LAPI yet")
	}
	out := make([]netip.Prefix, 0, len(d.banned))
	for p := range d.banned {
		out = append(out, p)
	}
	return out, nil
}

func banPrefix(dec *models.Decision) (netip.Prefix, bool) {
	if dec == nil || dec.Type == nil || !strings.EqualFold(*dec.Type, "ban") || dec.Value == nil {
		return netip.Prefix{}, false
	}
	p, err := ParsePrefix(*dec.Value)
	if err != nil {
		slog.Warn("skipping decision", "value", *dec.Value, "error", err)
		return netip.Prefix{}, false
	}
	return p, true
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func run() error {
	lapiURL := os.Getenv("CROWDSEC_LAPI_URL")
	keyFile := os.Getenv("CROWDSEC_BOUNCER_KEY_FILE")
	if lapiURL == "" || keyFile == "" {
		return errors.New("CROWDSEC_LAPI_URL and CROWDSEC_BOUNCER_KEY_FILE are required")
	}
	chunkSize, err := strconv.Atoi(env("CHUNK_SIZE", "1000"))
	if err != nil || chunkSize < 1 {
		return fmt.Errorf("CHUNK_SIZE must be a positive integer")
	}
	interval, err := time.ParseDuration(env("SYNC_INTERVAL", "30s"))
	if err != nil || interval <= 0 {
		return fmt.Errorf("SYNC_INTERVAL must be a positive duration")
	}
	key, err := os.ReadFile(keyFile)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	restConfig, err := config.GetConfig()
	if err != nil {
		return err
	}
	k8s, err := client.New(restConfig, client.Options{Scheme: newScheme()})
	if err != nil {
		return err
	}

	registry := prometheus.NewRegistry()
	reconciler := &Reconciler{
		Client:      k8s,
		GroupPrefix: env("GROUP_PREFIX", "crowdsec-banned-"),
		ChunkSize:   chunkSize,
		Metrics:     newMetrics(registry),
	}

	bouncer := &csbouncer.StreamBouncer{
		APIUrl:              lapiURL,
		APIKey:              strings.TrimSpace(string(key)),
		TickerInterval:      "10s",
		Scopes:              []string{"ip", "range"},
		RetryInitialConnect: true,
		UserAgent:           "crowdsec-cilium-bouncer",
	}
	if err := bouncer.Init(); err != nil {
		return err
	}

	metrics := &http.Server{Addr: ":9090", Handler: promhttp.HandlerFor(registry, promhttp.HandlerOpts{})}
	go func() {
		if err := metrics.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
			slog.Error("metrics server", "error", err)
			stop()
		}
	}()

	state := &decisions{banned: map[netip.Prefix]struct{}{}}
	go func() {
		// After the first answer, LAPI errors are logged by the library and
		// retried; the last known state stays in place meanwhile.
		if err := bouncer.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("LAPI stream stopped", "error", err)
			stop()
		}
	}()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			return metrics.Shutdown(shutdown)
		case resp := <-bouncer.Stream:
			if resp != nil {
				state.apply(resp)
			}
		case <-ticker.C:
			if err := reconciler.Sync(ctx, state); err != nil {
				slog.Error("sync failed, groups left as they were", "error", err)
			}
		}
	}
}

func main() {
	if err := run(); err != nil {
		slog.Error("exiting", "error", err)
		os.Exit(1)
	}
}
