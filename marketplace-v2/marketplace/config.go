package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddr      string
	MetricsAddr     string // optional: serve Prometheus /metrics here (not on the UI listener)
	RPCURL          string
	ChainID         uint64
	ContractAddress string
	HTCondorStatus  string
	DataDir         string
	RentalsFile     string
	PollInterval    time.Duration
	StartBlock      uint64
	// Confirmations is how many blocks the chain watcher stays behind the head (default 3, about 36 s on
	// Sepolia). Lower it (1) for a live demo; each block of depth is a block of reorg protection you give up.
	Confirmations uint64
}

func loadConfig() Config {
	chainID, _ := strconv.ParseUint(env("CHAIN_ID", "11155111"), 10, 64)
	pollSeconds, _ := strconv.Atoi(env("CHAIN_POLL_SECONDS", "5"))
	if pollSeconds < 2 {
		pollSeconds = 2
	}
	dataDir := env("DATA_DIR", "./data")
	rentalsFile := env("RENTALS_FILE", "/tmp/rentals.json")
	startBlock, _ := strconv.ParseUint(env("START_BLOCK", "0"), 10, 64)
	confirmations, err := strconv.ParseUint(env("CONFIRMATIONS", strconv.Itoa(defaultConfirmations)), 10, 64)
	if err != nil || confirmations > 64 {
		confirmations = defaultConfirmations
	}
	return Config{
		ListenAddr:      env("LISTEN_ADDR", ":8080"),
		MetricsAddr:     strings.TrimSpace(os.Getenv("METRICS_ADDR")),
		RPCURL:          strings.TrimSpace(os.Getenv("RPC_URL")),
		ChainID:         chainID,
		ContractAddress: strings.TrimSpace(os.Getenv("CONTRACT_ADDRESS")),
		HTCondorStatus:  env("HTCONDOR_STATUS", "condor_status"),
		DataDir:         dataDir,
		RentalsFile:     rentalsFile,
		PollInterval:    time.Duration(pollSeconds) * time.Second,
		StartBlock:      startBlock,
		Confirmations:   confirmations,
	}
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
