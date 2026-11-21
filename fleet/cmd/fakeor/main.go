// Command fakeor serves the fake OpenRouter and a traffic trap on loopback
// for manual runs, printing each request as a JSON line on stdout.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/TanGentleman/tan-toolchains/fleet/fakeor"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8788", "fake OpenRouter address")
	trap := flag.String("trap", "127.0.0.1:8789", "refusing proxy address")
	key := flag.String("key", "sk-or-v1-fake", "accepted API key")
	flag.Parse()
	s := &fakeor.Server{Key: *key}
	t := &fakeor.Trap{}
	go func() { log.Fatal(http.ListenAndServe(*trap, t)) }()
	go func() {
		enc := json.NewEncoder(os.Stdout)
		n, h := 0, 0
		for range time.Tick(100 * time.Millisecond) {
			rs := s.Requests()
			for ; n < len(rs); n++ {
				enc.Encode(rs[n])
			}
			hs := t.Hosts()
			for ; h < len(hs); h++ {
				enc.Encode(map[string]string{"trap": hs[h]})
			}
		}
	}()
	log.Fatal(http.ListenAndServe(*listen, s))
}
