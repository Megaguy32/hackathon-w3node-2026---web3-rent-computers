package main

import (
	"encoding/hex"
	"path/filepath"
	"strings"
	"testing"
)

func TestContractEventTopicConstants(t *testing.T) {
	// Keccak-256 signatures for the event declarations in contracts/src/ComputeMarketplace.sol.
	if listingCreatedTopic != "0xee9a77e54ddc4ae3475a5616f641d8617975557d8f946292108c2b98c6a7bed3" {
		t.Fatalf("ListingCreated event topic does not match the contract ABI: %s", listingCreatedTopic)
	}
	if rentalCreatedTopic != "0xec629e63935ac5c5900777ba2f0204a90aa022089dbcccb2689ab9408399d767" {
		t.Fatalf("RentalCreated event topic does not match the contract ABI: %s", rentalCreatedTopic)
	}
}

func TestDecodeABIString(t *testing.T) {
	// ABI tuple: offset=0x20, then length=4 and bytes "test".
	d := make([]byte, 96)
	d[31] = 32
	d[63] = 4
	copy(d[64:], []byte("test"))
	got, err := abiString(d, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != "test" {
		t.Fatalf("got %q", got)
	}
}

func TestDecodeABINumber(t *testing.T) {
	d := make([]byte, 64)
	d[31] = 0x2a
	got, err := abiUint(d, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got != "42" {
		t.Fatalf("got %q", got)
	}
}

func TestTopicAddress(t *testing.T) {
	want := "0x1234567890abcdef1234567890abcdef12345678"
	word := make([]byte, 32)
	copy(word[12:], mustHex(t, strings.TrimPrefix(want, "0x")))
	got, err := topicAddress("0x" + hex.EncodeToString(word))
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestApplyRentalEventMatchesContractLayout(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStore(filepath.Join(dir, "data"), filepath.Join(dir, "rentals.json"))
	if err != nil {
		t.Fatal(err)
	}
	watcher := &ChainWatcher{store: store}

	provider := "0x1234567890abcdef1234567890abcdef12345678"
	machine := "provider-01.example"
	// RentalCreated non-indexed data layout from ComputeMarketplace.sol:
	// provider(address), machineName(string), expiresAt(uint256), paidWei(uint256).
	data := make([]byte, 4*32+32)
	copy(data[12:32], mustHex(t, strings.TrimPrefix(provider, "0x")))
	putWordUint(data[32:64], 128) // dynamic string offset
	putWordUint(data[64:96], 1_900_000_000)
	putWordUint(data[96:128], 1_000_000_000_000_000)
	putWordUint(data[128:160], uint64(len(machine)))
	padded := make([]byte, ((len(machine)+31)/32)*32)
	copy(padded, []byte(machine))
	data = append(data, padded...)

	lg := chainLog{
		Topics: []string{
			rentalCreatedTopic,
			wordHexUint(7),
			wordHexUint(2),
			wordHexAddress(t, "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"),
		},
		Data: "0x" + hex.EncodeToString(data),
	}
	if err := watcher.applyRentalLog(lg); err != nil {
		t.Fatal(err)
	}
	got := store.RentalMap()["7"]
	if got.MachineName != machine || got.Provider != provider || got.ListingID != "2" {
		t.Fatalf("unexpected rental: %+v", got)
	}
	if got.ExpiresAt != 1_900_000_000 || got.PaidWei != "1000000000000000" {
		t.Fatalf("unexpected rental amounts/timestamps: %+v", got)
	}
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func putWordUint(dst []byte, value uint64) {
	for i := 0; i < 8; i++ {
		dst[31-i] = byte(value)
		value >>= 8
	}
}

func wordHexUint(value uint64) string {
	word := make([]byte, 32)
	putWordUint(word, value)
	return "0x" + hex.EncodeToString(word)
}

func wordHexAddress(t *testing.T, address string) string {
	t.Helper()
	word := make([]byte, 32)
	decoded := mustHex(t, strings.TrimPrefix(address, "0x"))
	copy(word[12:], decoded)
	return "0x" + hex.EncodeToString(word)
}

func TestListingUpdatedEventUpdatesStore(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStore(filepath.Join(dir, "data"), filepath.Join(dir, "rentals.json"))
	if err != nil {
		t.Fatal(err)
	}
	watcher := &ChainWatcher{store: store}
	if err := store.PutListing(Listing{ListingID: "3", Provider: "0xabc", MachineName: "m", PriceWei: "10", DurationSeconds: 3600, Active: true}); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 96)
	putWordUint(data[0:32], 25)
	putWordUint(data[32:64], 7200)
	putWordUint(data[64:96], 0) // active = false
	lg := chainLog{Topics: []string{listingUpdatedTopic, wordHexUint(3)}, Data: "0x" + hex.EncodeToString(data)}
	if err := watcher.applyListingUpdatedLog(lg); err != nil {
		t.Fatal(err)
	}
	got := store.Listings()[0]
	if got.PriceWei != "25" || got.DurationSeconds != 7200 || got.Active {
		t.Fatalf("unexpected listing after update: %+v", got)
	}
	if n := len(store.ActiveListings()); n != 0 {
		t.Fatalf("inactive listing must not be offered, got %d", n)
	}
}

func TestCursorIsBoundToChainAndContract(t *testing.T) {
	dir := t.TempDir()
	store, _ := NewStore(filepath.Join(dir, "data"), filepath.Join(dir, "rentals.json"))
	cfg := Config{ChainID: 11155111, ContractAddress: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", StartBlock: 500, DataDir: dir}
	w := NewChainWatcher(cfg, store)
	if err := w.saveCursor(900); err != nil {
		t.Fatal(err)
	}
	got, err := w.loadCursor(nil)
	if err != nil || got != 900 {
		t.Fatalf("same contract should resume: got %d err %v", got, err)
	}
	cfg.ContractAddress = "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
	w2 := NewChainWatcher(cfg, store)
	got, err = w2.loadCursor(nil)
	if err != nil || got != 500 {
		t.Fatalf("new contract should restart at START_BLOCK: got %d err %v", got, err)
	}
}
