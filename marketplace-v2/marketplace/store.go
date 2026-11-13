package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Listing struct {
	ListingID       string `json:"listingId"`
	Provider        string `json:"provider"`
	MachineName     string `json:"machineName"`
	PriceWei        string `json:"priceWei"`
	DurationSeconds int64  `json:"durationSeconds"`
	Active          bool   `json:"active"`
	CreatedAt       int64  `json:"createdAt"`
}

type Rental struct {
	RentalID    string `json:"rentalId"`
	ListingID   string `json:"listingId"`
	Consumer    string `json:"consumer"`
	Provider    string `json:"provider"`
	MachineName string `json:"machineName"`
	ExpiresAt   int64  `json:"expiresAt"`
	PaidWei     string `json:"paidWei"`
	CreatedAt   int64  `json:"createdAt"`
}

type diskState struct {
	Listings map[string]Listing `json:"listings"`
	Rentals  map[string]Rental  `json:"rentals"`
}

type Store struct {
	mu          sync.RWMutex
	statePath   string
	rentalsPath string
	data        diskState
}

func NewStore(dataDir, rentalsPath string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(rentalsPath), 0755); err != nil {
		return nil, err
	}
	s := &Store{
		statePath:   filepath.Join(dataDir, "state.json"),
		rentalsPath: rentalsPath,
		data:        diskState{Listings: map[string]Listing{}, Rentals: map[string]Rental{}},
	}
	if b, err := os.ReadFile(s.statePath); err == nil {
		if err := json.Unmarshal(b, &s.data); err != nil {
			return nil, fmt.Errorf("decode state file: %w", err)
		}
		if s.data.Listings == nil {
			s.data.Listings = map[string]Listing{}
		}
		if s.data.Rentals == nil {
			s.data.Rentals = map[string]Rental{}
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	if err := s.writeRentalsLocked(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) PutListing(v Listing) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.Listings[v.ListingID] = v
	return s.persistLocked()
}

// UpdateListing applies a ListingUpdated event. An update for a listing the
// store has not seen (for example created before START_BLOCK) is ignored.
func (s *Store) UpdateListing(id, priceWei string, durationSeconds int64, active bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	l, ok := s.data.Listings[id]
	if !ok {
		return nil
	}
	l.PriceWei, l.DurationSeconds, l.Active = priceWei, durationSeconds, active
	s.data.Listings[id] = l
	return s.persistLocked()
}

func (s *Store) PutRental(v Rental) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.data.Rentals[v.RentalID] = v
	return s.persistLocked()
}

func (s *Store) Listings() []Listing {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Listing, 0, len(s.data.Listings))
	for _, v := range s.data.Listings {
		out = append(out, v)
	}
	return out
}

func (s *Store) ActiveListings() []Listing {
	out := []Listing{}
	for _, l := range s.Listings() {
		if l.Active {
			out = append(out, l)
		}
	}
	return out
}

func (s *Store) Rentals() []Rental {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Rental, 0, len(s.data.Rentals))
	for _, v := range s.data.Rentals {
		out = append(out, v)
	}
	return out
}

func (s *Store) RentalMap() map[string]Rental {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make(map[string]Rental, len(s.data.Rentals))
	for k, v := range s.data.Rentals {
		out[k] = v
	}
	return out
}

func (s *Store) persistLocked() error {
	if err := writeJSONAtomic(s.statePath, s.data, 0644); err != nil {
		return err
	}
	return s.writeRentalsLocked()
}

func (s *Store) writeRentalsLocked() error {
	// The plugin expects a flat object keyed by rental ID, with camelCase fields.
	return writeJSONAtomic(s.rentalsPath, s.data.Rentals, 0644)
}

func writeJSONAtomic(path string, value any, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.tmp.%d", path, time.Now().UnixNano())
	if err := os.WriteFile(tmp, append(b, '\n'), mode); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
