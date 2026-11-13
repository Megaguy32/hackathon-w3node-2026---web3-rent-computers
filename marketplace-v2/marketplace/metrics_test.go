package main

import (
	"strings"
	"testing"
)

func ad(machine, state string, apptainer bool) map[string]any {
	return map[string]any{"Machine": machine, "State": state, "HasSingularity": apptainer}
}

func TestClassifyFleet(t *testing.T) {
	ads := []map[string]any{
		// idle provider with Apptainer -> ready
		ad("idle.example", "Unclaimed", true),
		// partitionable slot: Unclaimed leftover + Claimed dynamic slot -> live (not ready)
		ad("busy.example", "Unclaimed", true), ad("busy.example", "Claimed", true),
		// rented, nothing running yet -> pending (not ready)
		ad("rented.example", "Unclaimed", true),
		// no Apptainer -> other
		ad("noapptainer.example", "Unclaimed", false),
		// draining/owner -> other
		ad("owner.example", "Owner", true),
	}
	c := classifyFleet(ads, map[string]bool{"rented.example": true, "busy.example": true})
	want := fleetCounts{Ready: 1, Pending: 1, Live: 1, Other: 2}
	if c != want {
		t.Fatalf("got %+v want %+v", c, want)
	}
}

func TestRentalStats(t *testing.T) {
	rented, active, expired := rentalStats([]Rental{
		{RentalID: "1", MachineName: "a", ExpiresAt: 100},
		{RentalID: "2", MachineName: "b", ExpiresAt: 300},
	}, 200)
	if active != 1 || expired != 1 || !rented["b"] || rented["a"] {
		t.Fatalf("active=%d expired=%d rented=%v", active, expired, sortedKeys(rented))
	}
}

func TestRenderMetricsFormat(t *testing.T) {
	out := renderMetrics(fleetCounts{Ready: 2, Pending: 1, Live: 3, Other: 0}, 6, 2, 1, 4, true)
	for _, line := range []string{
		`w3node_computes{state="ready"} 2`, `w3node_computes{state="pending"} 1`, `w3node_computes{state="live"} 3`,
		`w3node_computes_registered 6`, `w3node_listings_active 2`, `w3node_rentals{status="expired"} 4`, `w3node_pool_up 1`,
	} {
		if !strings.Contains(out, line+"\n") {
			t.Errorf("missing %q in:\n%s", line, out)
		}
	}
	if !strings.Contains(out, "# TYPE w3node_computes gauge") {
		t.Error("missing TYPE line")
	}
}
