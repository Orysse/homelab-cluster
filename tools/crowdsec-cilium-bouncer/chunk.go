package main

import (
	"net/netip"
	"slices"
	"strings"
)

// ParsePrefix reads a CrowdSec decision value: a single address (scope Ip)
// becomes a /32 or /128, a range (scope Range) is kept as given.
func ParsePrefix(value string) (netip.Prefix, error) {
	if strings.Contains(value, "/") {
		p, err := netip.ParsePrefix(value)
		if err != nil {
			return netip.Prefix{}, err
		}
		if p.Addr().Is4In6() {
			p = netip.PrefixFrom(p.Addr().Unmap(), max(p.Bits()-96, 0))
		}
		return p.Masked(), nil
	}
	addr, err := netip.ParseAddr(value)
	if err != nil {
		return netip.Prefix{}, err
	}
	addr = addr.Unmap()
	return netip.PrefixFrom(addr, addr.BitLen()), nil
}

// Chunk deduplicates and sorts prefixes, then splits them into groups of at
// most size. The same set always gives the same chunks, so an unchanged ban
// list never rewrites a CiliumCIDRGroup.
func Chunk(prefixes []netip.Prefix, size int) [][]netip.Prefix {
	sorted := slices.Clone(prefixes)
	slices.SortFunc(sorted, func(a, b netip.Prefix) int {
		if c := a.Addr().Compare(b.Addr()); c != 0 {
			return c
		}
		return a.Bits() - b.Bits()
	})
	sorted = slices.Compact(sorted)

	var chunks [][]netip.Prefix
	for chunk := range slices.Chunk(sorted, size) {
		chunks = append(chunks, chunk)
	}
	return chunks
}
