package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"
)

const maxCNAMEHops = 32

// 显式 Dial 超时，避免连上游 DNS 时长时间阻塞
var dnsResolver = &net.Resolver{
	PreferGo: true,
	Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		var d net.Dialer
		d.Timeout = 5 * time.Second
		return d.DialContext(ctx, network, address)
	},
}

type response struct {
	Domain     string   `json:"domain"`
	Canonical  string   `json:"canonical"`
	CNAMEChain []string `json:"cname_chain,omitempty"`
	IPs        []string `json:"ips"`
	Error      string   `json:"error,omitempty"`
}

func main() {
	log.SetOutput(os.Stdout)
	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + strings.TrimPrefix(strings.TrimSpace(p), ":")
	}
	srv := &http.Server{
		Addr:              addr,
		Handler:           routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		log.Printf("listen %s", addr)
		errCh <- srv.ListenAndServe()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-errCh:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	case <-sigCh:
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
	}
}

func routes() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	m.HandleFunc("/", resolve)
	return m
}

func resolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	domain := strings.TrimSpace(r.URL.Query().Get("domain"))
	if domain == "" {
		writeJSON(w, http.StatusBadRequest, response{Error: "missing query parameter: domain"})
		return
	}
	domain = strings.TrimSuffix(domain, ".")
	if domain == "" {
		writeJSON(w, http.StatusBadRequest, response{Error: "invalid domain"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()

	chain, canonical, err := followCNAME(ctx, domain)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, response{Domain: domain, Error: err.Error()})
		return
	}

	addrs, err := dnsResolver.LookupIPAddr(ctx, canonical)
	if err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, response{
			Domain: domain, Canonical: canonical, CNAMEChain: chain, Error: err.Error(),
		})
		return
	}
	var v4, v6 []string
	for _, a := range addrs {
		s := a.IP.String()
		if a.IP.To4() != nil {
			v4 = append(v4, s)
		} else {
			v6 = append(v6, s)
		}
	}
	sort.Strings(v4)
	sort.Strings(v6)
	ips := append(v4, v6...)
	writeJSON(w, http.StatusOK, response{Domain: domain, Canonical: canonical, CNAMEChain: chain, IPs: ips})
}

func writeJSON(w http.ResponseWriter, status int, body response) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(true)
	if err := enc.Encode(body); err != nil {
		log.Printf("json: %v", err)
	}
}

func followCNAME(ctx context.Context, host string) (chain []string, final string, err error) {
	res := dnsResolver
	cur := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
	if cur == "" {
		return nil, "", errors.New("empty host after normalization")
	}
	for i := 0; i < maxCNAMEHops; i++ {
		cname, err := res.LookupCNAME(ctx, cur)
		if err != nil {
			return chain, cur, nil
		}
		t := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(cname)), ".")
		if t == "" || t == cur {
			return chain, cur, nil
		}
		chain = append(chain, t)
		cur = t
	}
	return nil, "", errors.New("CNAME chain too long")
}
