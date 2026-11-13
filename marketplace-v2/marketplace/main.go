package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"
)

//go:embed templates/*.html static/* abi.json
var assets embed.FS

type App struct {
	cfg   Config
	store *Store
	tpl   *template.Template
}

type PageData struct {
	Config             Config
	ContractConfigured bool
	ChainName          string
	Nodes              []ComputeNode
	NodeError          string
	Listings           []Listing
	Rentals            []Rental
	Now                int64
}

func main() {
	cfg := loadConfig()
	store, err := NewStore(cfg.DataDir, cfg.RentalsFile)
	if err != nil {
		log.Fatalf("initialize state store: %v", err)
	}
	funcMap := template.FuncMap{
		"short": func(s string) string {
			if len(s) <= 13 {
				return s
			}
			return s[:7] + "…" + s[len(s)-4:]
		},
		"duration": func(seconds int64) string {
			if seconds%3600 == 0 {
				return fmt.Sprintf("%d h", seconds/3600)
			}
			if seconds%60 == 0 {
				return fmt.Sprintf("%d min", seconds/60)
			}
			return fmt.Sprintf("%d s", seconds)
		},
		"timestamp": func(ts int64) string { return time.Unix(ts, 0).UTC().Format("2006-01-02 15:04 UTC") },
		"eth": func(wei string) string {
			n, ok := new(big.Int).SetString(wei, 10)
			if !ok {
				return wei
			}
			whole, frac := new(big.Int), new(big.Int)
			whole.QuoRem(n, big.NewInt(1_000_000_000_000_000_000), frac)
			if frac.Sign() == 0 {
				return whole.String()
			}
			fraction := strings.Repeat("0", 18-len(frac.String())) + frac.String()
			return whole.String() + "." + strings.TrimRight(fraction, "0")
		},
	}
	tpl, err := template.New("pages").Funcs(funcMap).ParseFS(assets, "templates/*.html")
	if err != nil {
		log.Fatalf("parse templates: %v", err)
	}
	app := &App{cfg: cfg, store: store, tpl: tpl}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go NewChainWatcher(cfg, store).Run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", app.handleIndex)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"status": "ok", "time": time.Now().UTC()})
	})
	mux.HandleFunc("GET /abi.json", func(w http.ResponseWriter, r *http.Request) {
		b, _ := assets.ReadFile("abi.json")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(b)
	})
	mux.HandleFunc("GET /api/config", app.handleConfig)
	mux.HandleFunc("GET /api/nodes", app.handleNodes)
	mux.HandleFunc("GET /api/listings", app.handleListings)
	mux.HandleFunc("GET /api/rentals", app.handleRentals)
	mux.HandleFunc("GET /partial/nodes", app.handleNodeRows)
	mux.HandleFunc("GET /partial/node-options", app.handleNodeOptions)
	mux.HandleFunc("GET /partial/listings", app.handleListingRows)
	mux.HandleFunc("GET /partial/rentals", app.handleRentalRows)
	staticFS, _ := fs.Sub(assets, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))

	server := &http.Server{Addr: cfg.ListenAddr, Handler: securityHeaders(mux), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutdownCancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("W3Node compute marketplace listening on %s", cfg.ListenAddr)
	if cfg.RPCURL == "" || cfg.ContractAddress == "" {
		log.Printf("chain listener disabled until RPC_URL and CONTRACT_ADDRESS are configured")
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("HTTP server: %v", err)
	}
}

func (a *App) pageData() PageData {
	nodes, err := listComputeNodes(a.cfg.HTCondorStatus)
	nodeErr := ""
	if err != nil {
		nodeErr = err.Error()
	}
	listings := a.store.Listings()
	rentals := a.store.Rentals()
	sort.Slice(listings, func(i, j int) bool { return numericLess(listings[i].ListingID, listings[j].ListingID) })
	sort.Slice(rentals, func(i, j int) bool { return numericLess(rentals[j].RentalID, rentals[i].RentalID) })
	name := "Ethereum Sepolia"
	return PageData{Config: a.cfg, ContractConfigured: a.cfg.ContractAddress != "" && a.cfg.RPCURL != "", ChainName: name, Nodes: nodes, NodeError: nodeErr, Listings: listings, Rentals: rentals, Now: time.Now().Unix()}
}
func numericLess(a, b string) bool {
	left, okLeft := new(big.Int).SetString(a, 10)
	right, okRight := new(big.Int).SetString(b, 10)
	if okLeft && okRight {
		return left.Cmp(right) < 0
	}
	return a < b
}
func (a *App) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if err := a.tpl.ExecuteTemplate(w, "index.html", a.pageData()); err != nil {
		http.Error(w, err.Error(), 500)
	}
}
func (a *App) handleConfig(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"chainId": a.cfg.ChainID, "contractAddress": a.cfg.ContractAddress, "chainName": "Ethereum Sepolia", "configured": a.cfg.ContractAddress != "" && a.cfg.RPCURL != ""})
}
func (a *App) handleNodes(w http.ResponseWriter, r *http.Request) {
	nodes, err := listComputeNodes(a.cfg.HTCondorStatus)
	if err != nil {
		http.Error(w, err.Error(), 503)
		return
	}
	writeJSON(w, nodes)
}
func (a *App) handleListings(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, a.store.Listings())
}
func (a *App) handleRentals(w http.ResponseWriter, r *http.Request) { writeJSON(w, a.store.Rentals()) }
func (a *App) handleNodeRows(w http.ResponseWriter, r *http.Request) {
	nodes, err := listComputeNodes(a.cfg.HTCondorStatus)
	data := map[string]any{"Nodes": nodes, "NodeError": ""}
	if err != nil {
		data["NodeError"] = err.Error()
	}
	if e := a.tpl.ExecuteTemplate(w, "node_rows.html", data); e != nil {
		http.Error(w, e.Error(), 500)
	}
}
func (a *App) handleListingRows(w http.ResponseWriter, r *http.Request) {
	if e := a.tpl.ExecuteTemplate(w, "listing_rows.html", map[string]any{"Listings": a.store.ActiveListings(), "Now": time.Now().Unix()}); e != nil {
		http.Error(w, e.Error(), 500)
	}
}
func (a *App) handleRentalRows(w http.ResponseWriter, r *http.Request) {
	if e := a.tpl.ExecuteTemplate(w, "rental_rows.html", map[string]any{"Rentals": a.store.Rentals(), "Now": time.Now().Unix()}); e != nil {
		http.Error(w, e.Error(), 500)
	}
}
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin")
		w.Header().Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

func (a *App) handleNodeOptions(w http.ResponseWriter, r *http.Request) {
	nodes, err := listComputeNodes(a.cfg.HTCondorStatus)
	data := map[string]any{"Nodes": nodes, "NodeError": ""}
	if err != nil {
		data["NodeError"] = err.Error()
	}
	if e := a.tpl.ExecuteTemplate(w, "node_options.html", data); e != nil {
		http.Error(w, e.Error(), 500)
	}
}
