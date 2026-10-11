// tgweb-net replaces curl and iproute2 in the runtime image, so the image does
// not need libcurl and its transitive libraries (GnuTLS, LDAP, RTMP, Kerberos).
//
//	tgweb-net get [-o FILE] [-4] [-timeout 30s] [-https] URL
//	    Fetch URL. Body goes to stdout or FILE; non-2xx exits with 22 (like curl --fail).
//	tgweb-net local-ip DEST-IP
//	    Print the local IPv4 address the kernel would use to reach DEST-IP
//	    (equivalent of `ip -4 route get DEST-IP`; no packet is sent).
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "get":
		os.Exit(get(os.Args[2:]))
	case "local-ip":
		os.Exit(localIP(os.Args[2:]))
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: tgweb-net get [-o FILE] [-4] [-timeout 30s] [-https] URL | tgweb-net local-ip DEST-IP")
	os.Exit(2)
}

func get(args []string) int {
	flags := flag.NewFlagSet("get", flag.ContinueOnError)
	output := flags.String("o", "", "write the body to FILE (atomically) instead of stdout")
	ipv4 := flags.Bool("4", false, "connect over IPv4 only")
	timeout := flags.Duration("timeout", 30*time.Second, "total request timeout")
	httpsOnly := flags.Bool("https", false, "refuse non-HTTPS URLs and redirects")
	if err := flags.Parse(args); err != nil || flags.NArg() != 1 {
		return 2
	}
	target := flags.Arg(0)

	dialer := &net.Dialer{Timeout: 10 * time.Second}
	transport := &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 10 * time.Second,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if *ipv4 {
				network = "tcp4"
			}
			return dialer.DialContext(ctx, network, address)
		},
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   *timeout,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			if *httpsOnly && request.URL.Scheme != "https" {
				return errors.New("redirect to a non-HTTPS URL refused")
			}
			return nil
		},
	}
	if *httpsOnly && !strings.HasPrefix(target, "https://") {
		fmt.Fprintln(os.Stderr, "tgweb-net: only https:// URLs are allowed")
		return 2
	}

	response, err := client.Get(target)
	if err != nil {
		fmt.Fprintf(os.Stderr, "tgweb-net: %v\n", err)
		return 7
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		fmt.Fprintf(os.Stderr, "tgweb-net: %s returned HTTP %d\n", target, response.StatusCode)
		return 22
	}

	if *output == "" || *output == os.DevNull {
		var sink io.Writer = os.Stdout
		if *output == os.DevNull {
			sink = io.Discard
		}
		if _, err := io.Copy(sink, response.Body); err != nil {
			fmt.Fprintf(os.Stderr, "tgweb-net: %v\n", err)
			return 23
		}
		return 0
	}
	temporary, err := os.CreateTemp(filepath.Dir(*output), filepath.Base(*output)+".tmp*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "tgweb-net: %v\n", err)
		return 23
	}
	_, copyErr := io.Copy(temporary, response.Body)
	closeErr := temporary.Close()
	if copyErr == nil {
		copyErr = closeErr
	}
	if copyErr == nil {
		copyErr = os.Rename(temporary.Name(), *output)
	}
	if copyErr != nil {
		os.Remove(temporary.Name())
		fmt.Fprintf(os.Stderr, "tgweb-net: %v\n", copyErr)
		return 23
	}
	return 0
}

func localIP(args []string) int {
	if len(args) != 1 || net.ParseIP(args[0]) == nil {
		usage()
	}
	// A UDP "connect" only selects a route and a source address.
	connection, err := net.Dial("udp4", net.JoinHostPort(args[0], "443"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "tgweb-net: %v\n", err)
		return 1
	}
	defer connection.Close()
	fmt.Println(connection.LocalAddr().(*net.UDPAddr).IP.String())
	return 0
}
