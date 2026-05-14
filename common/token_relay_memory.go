package common

import (
	"sync"
	"time"
)

// In-process sliding ~60s TPM window per token when Redis is disabled.
// Not shared across multiple API processes; use Redis in production clusters.

const tokenRelayTpmWindowMs = int64(60000)

var (
	tokenRelayTpmMemMu sync.Mutex
	tokenRelayTpmMem   = make(map[int][]tpmWindowEntry)
)

type tpmWindowEntry struct {
	ms int64
	n  int64
}

// TokenRelayTpmMemorySum returns total tokens in the last ~60s for tokenId (and drops expired entries).
func TokenRelayTpmMemorySum(tokenId int) int64 {
	if tokenId <= 0 {
		return 0
	}
	now := time.Now().UnixMilli()
	cutoff := now - tokenRelayTpmWindowMs

	tokenRelayTpmMemMu.Lock()
	defer tokenRelayTpmMemMu.Unlock()

	slice := tokenRelayTpmMem[tokenId]
	kept := make([]tpmWindowEntry, 0, len(slice))
	var sum int64
	for _, e := range slice {
		if e.ms >= cutoff {
			kept = append(kept, e)
			sum += e.n
		}
	}
	if len(kept) == 0 {
		delete(tokenRelayTpmMem, tokenId)
	} else {
		tokenRelayTpmMem[tokenId] = kept
	}
	return sum
}

// TokenRelayTpmMemoryAdd records prompt+completion tokens for the sliding TPM window.
func TokenRelayTpmMemoryAdd(tokenId int, n int64) {
	if tokenId <= 0 || n < 0 {
		return
	}
	now := time.Now().UnixMilli()
	cutoff := now - tokenRelayTpmWindowMs

	tokenRelayTpmMemMu.Lock()
	defer tokenRelayTpmMemMu.Unlock()

	slice := tokenRelayTpmMem[tokenId]
	kept := make([]tpmWindowEntry, 0, len(slice)+1)
	for _, e := range slice {
		if e.ms >= cutoff {
			kept = append(kept, e)
		}
	}
	kept = append(kept, tpmWindowEntry{ms: now, n: n})
	tokenRelayTpmMem[tokenId] = kept
}
