package main

import (
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddr      string
	RPCURL          string
	ChainID         uint64
	ContractAddress string
	HTCondorStatus  string
	DataDir         string
	RentalsFile     string
	PollInterval    time.Duration
	StartBlock      uint64
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
	return Config{
		ListenAddr:      env("LISTEN_ADDR", ":8080"),
		RPCURL:          strings.TrimSpace(os.Getenv("RPC_URL")),
		ChainID:         chainID,
		ContractAddress: strings.TrimSpace(os.Getenv("CONTRACT_ADDRESS")),
		HTCondorStatus:  env("HTCONDOR_STATUS", "condor_status"),
		DataDir:         dataDir,
		RentalsFile:     rentalsFile,
		PollInterval:    time.Duration(pollSeconds) * time.Second,
		StartBlock:      startBlock,
	}
}

func env(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}
