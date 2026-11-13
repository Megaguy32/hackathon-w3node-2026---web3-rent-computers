package main

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

// Fleet categories for the Grafana "compute" counters. Every provider machine in the pool falls into
// exactly one of them:
//
//	live    - at least one slot is Claimed: a rented workload is running on the machine right now
//	pending - not live, but an unexpired rental exists on it: rented and waiting for its workload
//	ready   - idle, Apptainer-capable and not rented: available to rent
//	other   - registered in the pool but unusable (no Apptainer, Owner/Drained/Matched, ...)
//
// Partitionable slots keep an Unclaimed leftover slot while a dynamic slot runs a job, so the machine
// state has to be derived from all of the machine's ClassAds, not from the de-duplicated node list.
type fleetCounts struct {
	Ready, Pending, Live, Other int
}

// machineStates classifies every machine in the pool: "live", "pending", "ready" or "other".
func machineStates(ads []map[string]any, rentedMachines map[string]bool) map[string]string {
	type seen struct{ claimed, idleApptainer bool }
	machines := map[string]*seen{}
	for _, ad := range ads {
		m := stringField(ad, "Machine")
		if m == "" {
			continue
		}
		s := machines[m]
		if s == nil {
			s = &seen{}
			machines[m] = s
		}
		state := stringField(ad, "State")
		if strings.EqualFold(state, "Claimed") {
			s.claimed = true
		}
		if strings.EqualFold(state, "Unclaimed") && boolField(ad, "HasSingularity") {
			s.idleApptainer = true
		}
	}
	out := make(map[string]string, len(machines))
	for name, s := range machines {
		switch {
		case s.claimed:
			out[name] = "live"
		case rentedMachines[name]:
			out[name] = "pending"
		case s.idleApptainer:
			out[name] = "ready"
		default:
			out[name] = "other"
		}
	}
	return out
}

func classifyFleet(ads []map[string]any, rentedMachines map[string]bool) fleetCounts {
	var c fleetCounts
	for _, st := range machineStates(ads, rentedMachines) {
		switch st {
		case "live":
			c.Live++
		case "pending":
			c.Pending++
		case "ready":
			c.Ready++
		default:
			c.Other++
		}
	}
	return c
}

// rentalStats returns the machines with an unexpired rental plus active/expired rental counts.
func rentalStats(rentals []Rental, now int64) (rented map[string]bool, active, expired int) {
	rented = map[string]bool{}
	for _, r := range rentals {
		if r.ExpiresAt > now {
			active++
			rented[r.MachineName] = true
		} else {
			expired++
		}
	}
	return
}

func renderMetrics(c fleetCounts, registered, activeListings, activeRentals, expiredRentals int, poolUp bool) string {
	var b strings.Builder
	gauge := func(name, help string) { fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n", name, help, name) }
	gauge("w3node_computes", "Provider machines in the pool by marketplace state (ready=available to rent, pending=rented and waiting for a workload, live=running a rented workload, other=unusable).")
	for _, kv := range []struct {
		k string
		v int
	}{{"ready", c.Ready}, {"pending", c.Pending}, {"live", c.Live}, {"other", c.Other}} {
		fmt.Fprintf(&b, "w3node_computes{state=%q} %d\n", kv.k, kv.v)
	}
	gauge("w3node_computes_registered", "Provider machines currently advertised in the HTCondor pool.")
	fmt.Fprintf(&b, "w3node_computes_registered %d\n", registered)
	gauge("w3node_listings_active", "Active marketplace listings indexed from the chain.")
	fmt.Fprintf(&b, "w3node_listings_active %d\n", activeListings)
	gauge("w3node_rentals", "Rentals indexed from the chain by status.")
	fmt.Fprintf(&b, "w3node_rentals{status=\"active\"} %d\nw3node_rentals{status=\"expired\"} %d\n", activeRentals, expiredRentals)
	gauge("w3node_pool_up", "1 if condor_status could be queried, 0 otherwise.")
	up := 0
	if poolUp {
		up = 1
	}
	fmt.Fprintf(&b, "w3node_pool_up %d\n", up)
	return b.String()
}

func (a *App) handleMetrics(w http.ResponseWriter, r *http.Request) {
	now := time.Now().Unix()
	rented, active, expired := rentalStats(a.store.Rentals(), now)
	ads, err := readAds(a.cfg.HTCondorStatus)
	counts, registered := fleetCounts{}, 0
	if err == nil {
		counts = classifyFleet(ads, rented)
		registered = counts.Ready + counts.Pending + counts.Live + counts.Other
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	fmt.Fprint(w, renderMetrics(counts, registered, len(a.store.ActiveListings()), active, expired, err == nil))
}

// sortedKeys is used by tests for stable output.
func sortedKeys(m map[string]bool) []string {
	k := make([]string, 0, len(m))
	for key := range m {
		k = append(k, key)
	}
	sort.Strings(k)
	return k
}
