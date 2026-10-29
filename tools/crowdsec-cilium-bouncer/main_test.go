package main

import (
	"net/netip"
	"testing"

	"github.com/crowdsecurity/crowdsec/pkg/models"
)

func decision(kind, value string) *models.Decision {
	return &models.Decision{Type: &kind, Value: &value}
}

func TestDecisionsRefuseBeforeFirstAnswer(t *testing.T) {
	d := &decisions{banned: map[netip.Prefix]struct{}{}}
	if _, err := d.Prefixes(); err == nil {
		t.Fatal("Prefixes() before any LAPI answer returned no error; an empty set would delete every group")
	}

	d.apply(&models.DecisionsStreamResponse{})
	got, err := d.Prefixes()
	if err != nil || len(got) != 0 {
		t.Fatalf("after an empty startup answer: got %v, %v; want an empty set", got, err)
	}
}

func TestDecisionsApplyNewAndDeleted(t *testing.T) {
	d := &decisions{banned: map[netip.Prefix]struct{}{}}
	d.apply(&models.DecisionsStreamResponse{New: []*models.Decision{
		decision("ban", "192.0.2.1"),
		decision("ban", "198.51.100.0/24"),
		decision("captcha", "192.0.2.9"),
	}})
	d.apply(&models.DecisionsStreamResponse{Deleted: []*models.Decision{
		decision("ban", "192.0.2.1"),
	}})

	got, err := d.Prefixes()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].String() != "198.51.100.0/24" {
		t.Fatalf("got %v, want [198.51.100.0/24]", got)
	}
}
