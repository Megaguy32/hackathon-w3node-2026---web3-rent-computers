package main

import "testing"

func TestBuildLive(t *testing.T) {
	ads := []map[string]any{
		ad("idle.example", "Unclaimed", true),
		ad("busy.example", "Unclaimed", true), ad("busy.example", "Claimed", true),
		ad("rented.example", "Unclaimed", true),
	}
	listings := []Listing{
		{ListingID: "1", MachineName: "idle.example", PriceWei: "5", Active: true},
		{ListingID: "2", MachineName: "down.example", PriceWei: "7", Active: true}, // listed but not in the pool
		{ListingID: "3", MachineName: "gone.example", PriceWei: "9", Active: false},
	}
	rentals := []Rental{{RentalID: "9", MachineName: "rented.example", ExpiresAt: 1100}, {RentalID: "8", MachineName: "busy.example", ExpiresAt: 1500}}
	v := buildLive(ads, true, listings, rentals, nil, 1000, "https://x")
	got := map[string]string{}
	for _, tl := range v.Tiles {
		got[tl.Machine] = tl.State
	}
	want := map[string]string{"idle.example": "ready", "busy.example": "live", "rented.example": "pending", "down.example": "offline"}
	if len(got) != len(want) {
		t.Fatalf("tiles %v want %v", got, want)
	}
	for k, w := range want {
		if got[k] != w {
			t.Errorf("%s: %s want %s", k, got[k], w)
		}
	}
	if v.Counters.Ready != 1 || v.Counters.Live != 1 || v.Counters.Pending != 1 || v.Counters.Offline != 1 || v.Counters.Registered != 3 {
		t.Errorf("counters %+v", v.Counters)
	}
	for _, tl := range v.Tiles {
		if tl.Machine == "rented.example" && (tl.RentalID != "9" || tl.RentalEndsIn != 100) {
			t.Errorf("rental info %+v", tl)
		}
		if tl.Machine == "idle.example" && tl.ListingID != "1" {
			t.Errorf("listing info %+v", tl)
		}
	}
}

func TestEventsDedupeAndOrder(t *testing.T) {
	st, err := NewStore(t.TempDir(), t.TempDir()+"/rentals.json")
	if err != nil {
		t.Fatal(err)
	}
	_ = st.AddEvent(Event{Kind: "listing", ID: "1", Tx: "0xa", Block: 10})
	_ = st.AddEvent(Event{Kind: "rental", ID: "1", Tx: "0xb", Block: 20})
	_ = st.AddEvent(Event{Kind: "listing", ID: "1", Tx: "0xa", Block: 10}) // duplicate (re-index)
	ev := st.Events()
	if len(ev) != 2 || ev[0].Kind != "rental" || ev[1].Kind != "listing" {
		t.Fatalf("events %+v", ev)
	}
}
