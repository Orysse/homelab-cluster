package main

import (
	"context"
	"errors"
	"net/netip"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

type writes struct{ creates, updates, deletes int }

func newTestReconciler(t *testing.T, w *writes, objects ...client.Object) *Reconciler {
	t.Helper()
	c := fake.NewClientBuilder().
		WithScheme(newScheme()).
		WithObjects(objects...).
		WithInterceptorFuncs(interceptor.Funcs{
			Create: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.CreateOption) error {
				w.creates++
				return c.Create(ctx, obj, opts...)
			},
			Update: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.UpdateOption) error {
				w.updates++
				return c.Update(ctx, obj, opts...)
			},
			Delete: func(ctx context.Context, c client.WithWatch, obj client.Object, opts ...client.DeleteOption) error {
				w.deletes++
				return c.Delete(ctx, obj, opts...)
			},
		}).
		Build()
	return &Reconciler{
		Client:      c,
		GroupPrefix: "crowdsec-banned-",
		ChunkSize:   2,
		Metrics:     newMetrics(prometheus.NewRegistry()),
	}
}

func ownedGroup(name string, cidrs ...string) *CiliumCIDRGroup {
	return &CiliumCIDRGroup{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: groupLabels()},
		Spec:       CiliumCIDRGroupSpec{ExternalCIDRs: cidrs},
	}
}

func groupNames(t *testing.T, r *Reconciler) map[string][]string {
	t.Helper()
	var list CiliumCIDRGroupList
	if err := r.Client.List(context.Background(), &list); err != nil {
		t.Fatal(err)
	}
	out := map[string][]string{}
	for _, g := range list.Items {
		out[g.Name] = g.Spec.ExternalCIDRs
	}
	return out
}

type staticSource struct {
	prefixes []netip.Prefix
	err      error
}

func (s staticSource) Prefixes() ([]netip.Prefix, error) { return s.prefixes, s.err }

func TestReconcileCreatesAndDeletes(t *testing.T) {
	var w writes
	other := &CiliumCIDRGroup{
		ObjectMeta: metav1.ObjectMeta{Name: "other"},
		Spec:       CiliumCIDRGroupSpec{ExternalCIDRs: []string{"203.0.113.0/24"}},
	}
	r := newTestReconciler(t, &w,
		ownedGroup("crowdsec-banned-0", "192.0.2.1/32"),
		ownedGroup("crowdsec-banned-1", "192.0.2.2/32"),
		ownedGroup("crowdsec-banned-2", "192.0.2.3/32"),
		other,
	)

	desired := Chunk(prefixes(t, "192.0.2.1", "192.0.2.2", "192.0.2.3"), 2)
	if err := r.Reconcile(context.Background(), desired); err != nil {
		t.Fatal(err)
	}

	got := groupNames(t, r)
	if len(got) != 3 {
		t.Fatalf("groups = %v, want crowdsec-banned-0, crowdsec-banned-1 and other", got)
	}
	if want := []string{"192.0.2.1/32", "192.0.2.2/32"}; !equal(got["crowdsec-banned-0"], want) {
		t.Errorf("crowdsec-banned-0 = %v, want %v", got["crowdsec-banned-0"], want)
	}
	if want := []string{"192.0.2.3/32"}; !equal(got["crowdsec-banned-1"], want) {
		t.Errorf("crowdsec-banned-1 = %v, want %v", got["crowdsec-banned-1"], want)
	}
	if _, ok := got["crowdsec-banned-2"]; ok {
		t.Error("crowdsec-banned-2 should be deleted")
	}
	if want := []string{"203.0.113.0/24"}; !equal(got["other"], want) {
		t.Errorf("other = %v, want it untouched", got["other"])
	}
	if w.deletes != 1 {
		t.Errorf("deletes = %d, want 1", w.deletes)
	}
}

func TestReconcileNoopWhenUnchanged(t *testing.T) {
	var w writes
	r := newTestReconciler(t, &w,
		ownedGroup("crowdsec-banned-0", "192.0.2.1/32", "192.0.2.2/32"),
	)

	desired := Chunk(prefixes(t, "192.0.2.2", "192.0.2.1"), 2)
	if err := r.Reconcile(context.Background(), desired); err != nil {
		t.Fatal(err)
	}
	if w != (writes{}) {
		t.Fatalf("writes = %+v, want none", w)
	}
}

func TestReconcileKeepsGroupsOnSourceError(t *testing.T) {
	var w writes
	r := newTestReconciler(t, &w,
		ownedGroup("crowdsec-banned-0", "192.0.2.1/32"),
	)

	err := r.Sync(context.Background(), staticSource{err: errors.New("lapi unreachable")})
	if err == nil {
		t.Fatal("Sync returned nil, want the source error")
	}
	if w != (writes{}) {
		t.Fatalf("writes = %+v, want none", w)
	}
	if got := testutil.ToFloat64(r.Metrics.SyncErrors); got != 1 {
		t.Fatalf("bouncer_sync_errors_total = %v, want 1", got)
	}
	if got := groupNames(t, r); !equal(got["crowdsec-banned-0"], []string{"192.0.2.1/32"}) {
		t.Fatalf("crowdsec-banned-0 = %v, want unchanged", got["crowdsec-banned-0"])
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
