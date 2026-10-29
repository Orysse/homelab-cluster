package main

import (
	"context"
	"fmt"
	"net/netip"
	"slices"
	"strconv"

	"github.com/prometheus/client_golang/prometheus"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const managedBy = "crowdsec-cilium-bouncer"

// groupLabels marks the groups this bouncer owns. Policies select them with
// crowdsec.net/banned; the bouncer lists them with managed-by.
func groupLabels() map[string]string {
	return map[string]string{
		"crowdsec.net/banned":          "true",
		"app.kubernetes.io/managed-by": managedBy,
	}
}

// Source gives the current set of banned prefixes. It returns an error while
// it does not know the full set (for example before the first LAPI answer).
type Source interface {
	Prefixes() ([]netip.Prefix, error)
}

type Metrics struct {
	BannedPrefixes prometheus.Gauge
	Groups         prometheus.Gauge
	SyncErrors     prometheus.Counter
}

func newMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		BannedPrefixes: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "bouncer_banned_prefixes",
			Help: "Banned prefixes written to CiliumCIDRGroups.",
		}),
		Groups: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "bouncer_groups",
			Help: "CiliumCIDRGroups owned by the bouncer.",
		}),
		SyncErrors: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "bouncer_sync_errors_total",
			Help: "Syncs that failed and left the groups as they were.",
		}),
	}
	reg.MustRegister(m.BannedPrefixes, m.Groups, m.SyncErrors)
	return m
}

type Reconciler struct {
	Client      client.Client
	GroupPrefix string
	ChunkSize   int
	Metrics     *Metrics
}

// Sync writes the source's prefixes to the cluster. On any error the groups
// keep their last content: a LAPI outage must not lift the bans.
func (r *Reconciler) Sync(ctx context.Context, src Source) error {
	prefixes, err := src.Prefixes()
	if err == nil {
		desired := Chunk(prefixes, r.ChunkSize)
		err = r.Reconcile(ctx, desired)
		if err == nil {
			banned := 0
			for _, chunk := range desired {
				banned += len(chunk)
			}
			r.Metrics.BannedPrefixes.Set(float64(banned))
			r.Metrics.Groups.Set(float64(len(desired)))
			return nil
		}
	}
	r.Metrics.SyncErrors.Inc()
	return err
}

// Reconcile makes the owned groups match desired: group n holds chunk n.
// Unchanged groups are not written, surplus owned groups are deleted, and
// groups without the managed-by label are never touched.
func (r *Reconciler) Reconcile(ctx context.Context, desired [][]netip.Prefix) error {
	var existing CiliumCIDRGroupList
	if err := r.Client.List(ctx, &existing,
		client.MatchingLabels{"app.kubernetes.io/managed-by": managedBy}); err != nil {
		return fmt.Errorf("list groups: %w", err)
	}
	byName := map[string]*CiliumCIDRGroup{}
	for i := range existing.Items {
		byName[existing.Items[i].Name] = &existing.Items[i]
	}

	for n, chunk := range desired {
		name := r.GroupPrefix + strconv.Itoa(n)
		cidrs := make([]string, len(chunk))
		for i, p := range chunk {
			cidrs[i] = p.String()
		}

		group, found := byName[name]
		delete(byName, name)
		switch {
		case !found:
			group = &CiliumCIDRGroup{
				ObjectMeta: metav1.ObjectMeta{Name: name, Labels: groupLabels()},
				Spec:       CiliumCIDRGroupSpec{ExternalCIDRs: cidrs},
			}
			if err := r.Client.Create(ctx, group); err != nil {
				return fmt.Errorf("create %s: %w", name, err)
			}
		case !slices.Equal(group.Spec.ExternalCIDRs, cidrs):
			group.Spec.ExternalCIDRs = cidrs
			if err := r.Client.Update(ctx, group); err != nil {
				return fmt.Errorf("update %s: %w", name, err)
			}
		}
	}

	for name, group := range byName {
		if err := r.Client.Delete(ctx, group); client.IgnoreNotFound(err) != nil {
			return fmt.Errorf("delete %s: %w", name, err)
		}
	}
	return nil
}
