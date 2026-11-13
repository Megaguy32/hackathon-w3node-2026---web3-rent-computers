package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestRentalMirrorMatchesPluginShape(t *testing.T) {
	dir := t.TempDir()
	rentalsPath := filepath.Join(dir, "rentals.json")
	store, err := NewStore(filepath.Join(dir, "data"), rentalsPath)
	if err != nil {
		t.Fatal(err)
	}
	want := Rental{RentalID: "17", ListingID: "3", Consumer: "0xabc", Provider: "0xdef", MachineName: "worker-01.example", ExpiresAt: 1900000000, PaidWei: "1000"}
	if err := store.PutRental(want); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(rentalsPath)
	if err != nil {
		t.Fatal(err)
	}
	var plugin map[string]map[string]any
	if err := json.Unmarshal(b, &plugin); err != nil {
		t.Fatal(err)
	}
	if plugin["17"]["machineName"] != want.MachineName {
		t.Fatalf("machineName = %v", plugin["17"]["machineName"])
	}
	if plugin["17"]["expiresAt"].(float64) != float64(want.ExpiresAt) {
		t.Fatalf("expiresAt = %v", plugin["17"]["expiresAt"])
	}
}
