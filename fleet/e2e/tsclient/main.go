// tsclient joins a tailnet as one user and runs requests against fleetd,
// printing "<status> <body>" per request. Each arg is "METHOD PATH [JSON]".
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"tailscale.com/tsnet"
)

func main() {
	host := flag.String("hostname", "client", "tailnet hostname")
	dir := flag.String("dir", "", "tsnet state dir")
	ctrl := flag.String("control", "", "control URL")
	target := flag.String("target", "", "fleetd base URL")
	flag.Parse()
	s := &tsnet.Server{Hostname: *host, Dir: *dir, ControlURL: *ctrl, AuthKey: os.Getenv("TS_AUTHKEY"), Logf: func(string, ...any) {}, UserLogf: func(string, ...any) {}}
	defer s.Close()
	if _, err := s.Up(context.Background()); err != nil {
		log.Fatal(err)
	}
	c := s.HTTPClient()
	c.Timeout = 15 * time.Second
	for _, step := range flag.Args() {
		parts := strings.SplitN(step, " ", 3)
		var resp *http.Response
		var err error
		for i := 0; i < 20; i++ { // the first packets wait for a peer path
			var body io.Reader
			if len(parts) == 3 {
				body = strings.NewReader(parts[2])
			}
			req, _ := http.NewRequest(parts[0], *target+parts[1], body)
			req.Header.Set("Content-Type", "application/json")
			if resp, err = c.Do(req); err == nil {
				break
			}
			time.Sleep(500 * time.Millisecond)
		}
		if err != nil {
			fmt.Println(0, err)
			continue
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		fmt.Println(resp.StatusCode, strings.TrimSpace(string(b)))
	}
}
