package main

import (
	"net/http"
	"sort"
	"sync"
	"time"
)

// LiveTile is one provider machine on the Live view.
type LiveTile struct {
	Machine      string `json:"machine"`
	State        string `json:"state"` // ready | pending | live | offline | other
	CPUs         int64  `json:"cpus"`
	MemoryMiB    int64  `json:"memoryMiB"`
	Apptainer    bool   `json:"apptainer"`
	ListingID    string `json:"listingId,omitempty"`
	PriceWei     string `json:"priceWei,omitempty"`
	RentalID     string `json:"rentalId,omitempty"`
	RentalEndsIn int64  `json:"rentalEndsInSeconds,omitempty"`
}

type LiveCounters struct {
	Ready, Pending, Live, Offline, Registered int
}

type LiveView struct {
	Now      int64        `json:"now"`
	Explorer string       `json:"explorer"`
	Counters LiveCounters `json:"counters"`
	Tiles    []LiveTile   `json:"tiles"`
	Events   []Event      `json:"events"`
	PoolUp   bool         `json:"poolUp"`
}

// buildLive merges the pool (condor ClassAds), listings and rentals into the Live view model.
// A machine that has an active listing but is not in the pool shows as "offline" (e.g. its VM is down).
func buildLive(ads []map[string]any, poolUp bool, listings []Listing, rentals []Rental, events []Event, now int64, explorer string) LiveView {
	rented, _, _ := rentalStats(rentals, now)
	states := machineStates(ads, rented)
	nodes := map[string]ComputeNode{}
	for _, n := range nodesFromAds(ads) {
		nodes[n.Machine] = n
	}
	listingByMachine := map[string]Listing{}
	for _, l := range listings {
		if l.Active {
			listingByMachine[l.MachineName] = l
		}
	}
	rentalByMachine := map[string]Rental{}
	for _, r := range rentals {
		if r.ExpiresAt > now {
			if cur, ok := rentalByMachine[r.MachineName]; !ok || r.ExpiresAt > cur.ExpiresAt {
				rentalByMachine[r.MachineName] = r
			}
		}
	}
	names := map[string]bool{}
	for m := range states {
		names[m] = true
	}
	for m := range listingByMachine {
		names[m] = true
	}
	order := make([]string, 0, len(names))
	for m := range names {
		order = append(order, m)
	}
	sort.Strings(order)

	v := LiveView{Now: now, Explorer: explorer, PoolUp: poolUp, Events: events}
	if len(v.Events) > 12 {
		v.Events = v.Events[:12]
	}
	for _, m := range order {
		t := LiveTile{Machine: m, State: "offline"}
		if st, ok := states[m]; ok {
			t.State = st
			n := nodes[m]
			t.CPUs, t.MemoryMiB = n.CPUs, n.MemoryMiB
			t.Apptainer = n.HasApptainer || st == "ready" || st == "live"
		}
		if l, ok := listingByMachine[m]; ok {
			t.ListingID, t.PriceWei = l.ListingID, l.PriceWei
		}
		if r, ok := rentalByMachine[m]; ok {
			t.RentalID, t.RentalEndsIn = r.RentalID, r.ExpiresAt-now
		}
		switch t.State {
		case "ready":
			v.Counters.Ready++
		case "pending":
			v.Counters.Pending++
		case "live":
			v.Counters.Live++
		case "offline":
			v.Counters.Offline++
		}
		if t.State != "offline" {
			v.Counters.Registered++
		}
		v.Tiles = append(v.Tiles, t)
	}
	return v
}

// liveCache keeps concurrent viewers from each shelling out to condor_status.
type liveCache struct {
	mu   sync.Mutex
	at   time.Time
	ads  []map[string]any
	up   bool
	last error
}

func (c *liveCache) get(binary string) ([]map[string]any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if time.Since(c.at) < 1500*time.Millisecond {
		return c.ads, c.up
	}
	ads, err := readAds(binary)
	c.at, c.ads, c.up, c.last = time.Now(), ads, err == nil, err
	return c.ads, c.up
}

var liveAds liveCache

func (a *App) handleLiveAPI(w http.ResponseWriter, r *http.Request) {
	ads, up := liveAds.get(a.cfg.HTCondorStatus)
	writeJSON(w, buildLive(ads, up, a.store.Listings(), a.store.Rentals(), a.store.Events(), time.Now().Unix(), a.cfg.ExplorerURL))
}

func (a *App) handleLivePage(w http.ResponseWriter, r *http.Request) {
	b, err := assets.ReadFile("templates/live.html")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(b)
}
