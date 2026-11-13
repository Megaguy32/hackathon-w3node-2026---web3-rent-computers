package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type ComputeNode struct {
	Machine      string `json:"machine"`
	Name         string `json:"name"`
	State        string `json:"state"`
	CPUs         int64  `json:"cpus"`
	MemoryMiB    int64  `json:"memoryMiB"`
	Arch         string `json:"arch"`
	OpSys        string `json:"opSys"`
	HasApptainer bool   `json:"hasApptainer"`
	Available    bool   `json:"available"`
}

func listComputeNodes(binary string) ([]ComputeNode, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, binary, "-json").Output()
	if err != nil {
		return nil, fmt.Errorf("%s -json: %w", binary, err)
	}
	var ads []map[string]any
	if err := json.Unmarshal(out, &ads); err != nil {
		return nil, fmt.Errorf("decode condor_status JSON: %w", err)
	}
	// condor_status commonly returns one ClassAd per slot. The marketplace
	// rents a provider machine, not an individual slot, so present one row per
	// Machine value. Keep the largest observed CPU/memory figures and consider
	// the machine available if at least one suitable slot is Unclaimed.
	byMachine := make(map[string]int)
	nodes := make([]ComputeNode, 0, len(ads))
	for _, ad := range ads {
		machine := stringField(ad, "Machine")
		if machine == "" {
			continue
		}
		state := stringField(ad, "State")
		hasApptainer := boolField(ad, "HasSingularity")
		node := ComputeNode{
			Machine:      machine,
			Name:         stringField(ad, "Name"),
			State:        state,
			CPUs:         intField(ad, "Cpus"),
			MemoryMiB:    intField(ad, "Memory"),
			Arch:         stringField(ad, "Arch"),
			OpSys:        stringField(ad, "OpSys"),
			HasApptainer: hasApptainer,
			Available:    strings.EqualFold(state, "Unclaimed") && hasApptainer,
		}
		if idx, ok := byMachine[machine]; ok {
			current := &nodes[idx]
			if node.CPUs > current.CPUs {
				current.CPUs = node.CPUs
			}
			if node.MemoryMiB > current.MemoryMiB {
				current.MemoryMiB = node.MemoryMiB
			}
			if node.Available {
				current.Available = true
				current.State = "Unclaimed"
				current.HasApptainer = true
				current.Name = node.Name
			}
			continue
		}
		byMachine[machine] = len(nodes)
		nodes = append(nodes, node)
	}
	return nodes, nil
}

func stringField(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func intField(m map[string]any, key string) int64 {
	v, ok := m[key]
	if !ok || v == nil {
		return 0
	}
	switch n := v.(type) {
	case float64:
		return int64(n)
	case json.Number:
		i, _ := n.Int64()
		return i
	case string:
		i, _ := strconv.ParseInt(n, 10, 64)
		return i
	default:
		return 0
	}
}
func boolField(m map[string]any, key string) bool {
	v, ok := m[key]
	if !ok || v == nil {
		return false
	}
	switch b := v.(type) {
	case bool:
		return b
	case string:
		return strings.EqualFold(b, "true")
	case float64:
		return b != 0
	default:
		return false
	}
}
