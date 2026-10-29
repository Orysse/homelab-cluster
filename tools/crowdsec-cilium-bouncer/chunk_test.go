package main

import (
	"net/netip"
	"reflect"
	"testing"
)

func prefixes(t *testing.T, values ...string) []netip.Prefix {
	t.Helper()
	out := make([]netip.Prefix, 0, len(values))
	for _, v := range values {
		p, err := ParsePrefix(v)
		if err != nil {
			t.Fatalf("ParsePrefix(%q): %v", v, err)
		}
		out = append(out, p)
	}
	return out
}

func TestChunkDeterministic(t *testing.T) {
	in := prefixes(t,
		"10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.6",
		"10.0.0.7", "10.0.0.8", "10.0.0.9", "10.0.0.10", "10.0.0.11",
	)
	reversed := make([]netip.Prefix, len(in))
	for i, p := range in {
		reversed[len(in)-1-i] = p
	}
	withDuplicates := append(append([]netip.Prefix{}, in...), in[3], in[7])

	a := Chunk(in, 5)
	b := Chunk(reversed, 5)
	c := Chunk(withDuplicates, 5)

	if !reflect.DeepEqual(a, b) {
		t.Fatalf("order changed the result:\n%v\n%v", a, b)
	}
	if !reflect.DeepEqual(a, c) {
		t.Fatalf("duplicates changed the result:\n%v\n%v", a, c)
	}
	var sizes []int
	for _, chunk := range a {
		sizes = append(sizes, len(chunk))
	}
	if !reflect.DeepEqual(sizes, []int{5, 5, 1}) {
		t.Fatalf("chunk sizes = %v, want [5 5 1]", sizes)
	}
}

func TestChunkIPv6AndIPv4(t *testing.T) {
	got := Chunk(prefixes(t, "2001:db8::1", "192.0.2.7", "198.51.100.0/24", "2001:db8:1::/48"), 10)

	want := []string{"192.0.2.7/32", "198.51.100.0/24", "2001:db8::1/128", "2001:db8:1::/48"}
	if len(got) != 1 {
		t.Fatalf("got %d chunks, want 1", len(got))
	}
	var gotStrings []string
	for _, p := range got[0] {
		gotStrings = append(gotStrings, p.String())
	}
	if !reflect.DeepEqual(gotStrings, want) {
		t.Fatalf("got %v, want %v", gotStrings, want)
	}
}
