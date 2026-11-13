package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	listingCreatedTopic = "0xee9a77e54ddc4ae3475a5616f641d8617975557d8f946292108c2b98c6a7bed3"
	rentalCreatedTopic  = "0xec629e63935ac5c5900777ba2f0204a90aa022089dbcccb2689ab9408399d767"
	listingUpdatedTopic = "0xd2326201b794480c95fc221341873c03b3693dda95bf505803fc788672cfff2b"

	// defaultConfirmations keeps the watcher a few blocks behind the head so a
	// shallow reorg cannot leave a phantom rental in the authorisation state.
	defaultConfirmations = 3
)

var addressPattern = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

type rpcClient struct {
	url    string
	client *http.Client
}
type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Method  string `json:"method"`
	Params  any    `json:"params"`
}
type rpcResponse struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}
type chainLog struct {
	Address         string   `json:"address"`
	Topics          []string `json:"topics"`
	Data            string   `json:"data"`
	BlockNumber     string   `json:"blockNumber"`
	TransactionHash string   `json:"transactionHash"`
}

type ChainWatcher struct {
	cfg        Config
	store      *Store
	rpc        rpcClient
	cursorPath string
}

func NewChainWatcher(cfg Config, store *Store) *ChainWatcher {
	return &ChainWatcher{cfg: cfg, store: store, rpc: rpcClient{url: cfg.RPCURL, client: &http.Client{Timeout: 20 * time.Second}}, cursorPath: filepath.Join(cfg.DataDir, "chain-cursor.json")}
}

func (c *ChainWatcher) Run(ctx context.Context) {
	if c.cfg.RPCURL == "" || !addressPattern.MatchString(c.cfg.ContractAddress) {
		log.Printf("chain listener disabled: set RPC_URL and a valid CONTRACT_ADDRESS")
		return
	}
	var chainHex string
	if err := c.rpcCall(ctx, "eth_chainId", []any{}, &chainHex); err != nil {
		log.Printf("chain listener cannot verify RPC chain: %v", err)
		return
	}
	chainValue, ok := new(big.Int).SetString(strings.TrimPrefix(chainHex, "0x"), 16)
	if !ok || !chainValue.IsUint64() || chainValue.Uint64() != c.cfg.ChainID {
		log.Printf("chain listener disabled: RPC chain ID %q does not match configured CHAIN_ID %d", chainHex, c.cfg.ChainID)
		return
	}
	cursor, err := c.loadCursor(ctx)
	if err != nil {
		log.Printf("chain listener cannot initialize: %v", err)
		return
	}
	log.Printf("chain listener active: chain=%d contract=%s fromBlock=%d", c.cfg.ChainID, c.cfg.ContractAddress, cursor)
	ticker := time.NewTicker(c.cfg.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			latest, err := c.blockNumber(ctx)
			if err != nil {
				log.Printf("chain block query: %v", err)
				continue
			}
			if latest < c.cfg.Confirmations {
				continue
			}
			latest -= c.cfg.Confirmations
			if latest < cursor {
				continue
			}
			if latest-cursor > 1000 { // Keep eth_getLogs requests bounded.
				latest = cursor + 999
			}
			if latest >= cursor {
				if err := c.processRange(ctx, cursor, latest); err != nil {
					log.Printf("chain log scan: %v", err)
					continue
				}
				cursor = latest + 1
				if err := c.saveCursor(cursor); err != nil {
					log.Printf("write chain cursor: %v", err)
				}
			}
		}
	}
}

type cursorFile struct {
	ChainID   uint64 `json:"chainId"`
	Contract  string `json:"contract"`
	NextBlock uint64 `json:"nextBlock"`
}

func (c *ChainWatcher) saveCursor(next uint64) error {
	return writeJSONAtomic(c.cursorPath, cursorFile{ChainID: c.cfg.ChainID, Contract: strings.ToLower(c.cfg.ContractAddress), NextBlock: next}, 0644)
}

// loadCursor resumes from a persisted cursor only if it was written for the
// same chain and contract; otherwise it starts again from START_BLOCK (or the
// current head when START_BLOCK is 0) so a redeployed contract is not skipped.
func (c *ChainWatcher) loadCursor(ctx context.Context) (uint64, error) {
	b, err := os.ReadFile(c.cursorPath)
	if err == nil {
		var v cursorFile
		if err := json.Unmarshal(b, &v); err != nil {
			return 0, err
		}
		if v.ChainID == c.cfg.ChainID && v.Contract == strings.ToLower(c.cfg.ContractAddress) {
			return v.NextBlock, nil
		}
		log.Printf("chain cursor belongs to a different chain/contract (%d/%s); restarting scan", v.ChainID, v.Contract)
	} else if !os.IsNotExist(err) {
		return 0, err
	}
	start := c.cfg.StartBlock
	if start == 0 {
		// Start at the current head by default. Start the backend before creating listings.
		head, err := c.blockNumber(ctx)
		if err != nil {
			return 0, err
		}
		start = head
	}
	if err := c.saveCursor(start); err != nil {
		return 0, err
	}
	return start, nil
}

func (c *ChainWatcher) rpcCall(ctx context.Context, method string, params any, dst any) error {
	body, _ := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: 1, Method: method, Params: params})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.rpc.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.rpc.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("RPC HTTP %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	var envelope rpcResponse
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return err
	}
	if envelope.Error != nil {
		return fmt.Errorf("RPC %d: %s", envelope.Error.Code, envelope.Error.Message)
	}
	if dst == nil {
		return nil
	}
	return json.Unmarshal(envelope.Result, dst)
}

func (c *ChainWatcher) blockNumber(ctx context.Context) (uint64, error) {
	var raw string
	if err := c.rpcCall(ctx, "eth_blockNumber", []any{}, &raw); err != nil {
		return 0, err
	}
	v, ok := new(big.Int).SetString(strings.TrimPrefix(raw, "0x"), 16)
	if !ok {
		return 0, fmt.Errorf("invalid block number %q", raw)
	}
	return v.Uint64(), nil
}

func (c *ChainWatcher) processRange(ctx context.Context, from, to uint64) error {
	for _, topic := range []string{listingCreatedTopic, listingUpdatedTopic, rentalCreatedTopic} {
		query := map[string]any{"fromBlock": fmt.Sprintf("0x%x", from), "toBlock": fmt.Sprintf("0x%x", to), "address": c.cfg.ContractAddress, "topics": []any{topic}}
		var logs []chainLog
		if err := c.rpcCall(ctx, "eth_getLogs", []any{query}, &logs); err != nil {
			return err
		}
		for _, lg := range logs {
			if len(lg.Topics) == 0 {
				continue
			}
			var err error
			if strings.EqualFold(lg.Topics[0], listingCreatedTopic) {
				err = c.applyListingLog(lg)
			} else if strings.EqualFold(lg.Topics[0], listingUpdatedTopic) {
				err = c.applyListingUpdatedLog(lg)
			} else if strings.EqualFold(lg.Topics[0], rentalCreatedTopic) {
				err = c.applyRentalLog(lg)
			}
			var perr *persistError
			if errors.As(err, &perr) {
				// State could not be written: do not advance the cursor.
				return err
			}
			if err != nil {
				log.Printf("skip malformed event %s: %v", lg.TransactionHash, err)
			}
		}
	}
	return nil
}

func (c *ChainWatcher) applyListingLog(l chainLog) error {
	if len(l.Topics) < 3 {
		return errors.New("ListingCreated missing indexed topics")
	}
	id, err := topicUint(l.Topics[1])
	if err != nil {
		return err
	}
	provider, err := topicAddress(l.Topics[2])
	if err != nil {
		return err
	}
	data, err := decodeHex(l.Data)
	if err != nil {
		return err
	}
	machine, err := abiString(data, 0)
	if err != nil {
		return err
	}
	price, err := abiUint(data, 1)
	if err != nil {
		return err
	}
	duration, err := abiUint(data, 2)
	if err != nil {
		return err
	}
	block, _ := parseHexUint(l.BlockNumber)
	if err := wrapPersist(c.store.PutListing(Listing{ListingID: id, Provider: provider, MachineName: machine, PriceWei: price, DurationSeconds: toInt64(duration), Active: true, CreatedAt: int64(block)})); err != nil {
		return err
	}
	return wrapPersist(c.store.AddEvent(Event{Kind: "listing", ID: id, Machine: machine, Actor: provider, PriceWei: price, Tx: l.TransactionHash, Block: block, Seen: time.Now().Unix()}))
}

// applyListingUpdatedLog handles ListingUpdated(listingId indexed, priceWei,
// durationSeconds, active).
func (c *ChainWatcher) applyListingUpdatedLog(l chainLog) error {
	if len(l.Topics) < 2 {
		return errors.New("ListingUpdated missing indexed topic")
	}
	id, err := topicUint(l.Topics[1])
	if err != nil {
		return err
	}
	data, err := decodeHex(l.Data)
	if err != nil {
		return err
	}
	price, err := abiUint(data, 0)
	if err != nil {
		return err
	}
	duration, err := abiUint(data, 1)
	if err != nil {
		return err
	}
	activeWord, err := word(data, 2)
	if err != nil {
		return err
	}
	active := new(big.Int).SetBytes(activeWord).Sign() != 0
	return wrapPersist(c.store.UpdateListing(id, price, toInt64(duration), active))
}

type persistError struct{ err error }

func (e *persistError) Error() string { return "persist state: " + e.err.Error() }
func (e *persistError) Unwrap() error { return e.err }
func wrapPersist(err error) error {
	if err == nil {
		return nil
	}
	return &persistError{err}
}

func (c *ChainWatcher) applyRentalLog(l chainLog) error {
	if len(l.Topics) < 4 {
		return errors.New("RentalCreated missing indexed topics")
	}
	rentalID, err := topicUint(l.Topics[1])
	if err != nil {
		return err
	}
	listingID, err := topicUint(l.Topics[2])
	if err != nil {
		return err
	}
	consumer, err := topicAddress(l.Topics[3])
	if err != nil {
		return err
	}
	data, err := decodeHex(l.Data)
	if err != nil {
		return err
	}
	provider, err := abiAddress(data, 0)
	if err != nil {
		return err
	}
	machine, err := abiString(data, 1)
	if err != nil {
		return err
	}
	expires, err := abiUint(data, 2)
	if err != nil {
		return err
	}
	paid, err := abiUint(data, 3)
	if err != nil {
		return err
	}
	if err := wrapPersist(c.store.PutRental(Rental{RentalID: rentalID, ListingID: listingID, Consumer: consumer, Provider: provider, MachineName: machine, ExpiresAt: toInt64(expires), PaidWei: paid, CreatedAt: time.Now().Unix()})); err != nil {
		return err
	}
	block, _ := parseHexUint(l.BlockNumber)
	return wrapPersist(c.store.AddEvent(Event{Kind: "rental", ID: rentalID, Machine: machine, Actor: consumer, PriceWei: paid, Tx: l.TransactionHash, Block: block, Seen: time.Now().Unix()}))
}

func decodeHex(s string) ([]byte, error) { return hex.DecodeString(strings.TrimPrefix(s, "0x")) }
func parseHexUint(s string) (uint64, error) {
	n, ok := new(big.Int).SetString(strings.TrimPrefix(s, "0x"), 16)
	if !ok {
		return 0, fmt.Errorf("bad hex uint %q", s)
	}
	return n.Uint64(), nil
}
func topicUint(s string) (string, error) {
	b, err := decodeHex(s)
	if err != nil || len(b) != 32 {
		return "", errors.New("invalid uint topic")
	}
	return new(big.Int).SetBytes(b).String(), nil
}
func topicAddress(s string) (string, error) {
	b, err := decodeHex(s)
	if err != nil || len(b) != 32 {
		return "", errors.New("invalid address topic")
	}
	return "0x" + hex.EncodeToString(b[12:]), nil
}
func word(data []byte, index int) ([]byte, error) {
	off := index * 32
	if off+32 > len(data) {
		return nil, errors.New("ABI data too short")
	}
	return data[off : off+32], nil
}
func abiUint(data []byte, index int) (string, error) {
	b, err := word(data, index)
	if err != nil {
		return "", err
	}
	return new(big.Int).SetBytes(b).String(), nil
}
func abiAddress(data []byte, index int) (string, error) {
	b, err := word(data, index)
	if err != nil {
		return "", err
	}
	return "0x" + hex.EncodeToString(b[12:]), nil
}
func abiString(data []byte, index int) (string, error) {
	ob, err := word(data, index)
	if err != nil {
		return "", err
	}
	offset := new(big.Int).SetBytes(ob).Int64()
	if offset < 0 || offset+32 > int64(len(data)) {
		return "", errors.New("invalid ABI string offset")
	}
	length := new(big.Int).SetBytes(data[offset : offset+32]).Int64()
	start := offset + 32
	if length < 0 || start+length > int64(len(data)) {
		return "", errors.New("invalid ABI string length")
	}
	return string(data[start : start+length]), nil
}
func toInt64(s string) int64 {
	n, _ := new(big.Int).SetString(s, 10)
	if n == nil || !n.IsInt64() {
		return 0
	}
	return n.Int64()
}
