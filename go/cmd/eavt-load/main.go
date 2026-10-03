// eavt-load loads the Receita Federal CNPJ open data into the EAVT stack over
// the query server's tx protocol.  Port of the reference `load_receita` loader.
//
// Usage:
//
//	eavt-load --n 5000                    # quick test
//	eavt-load                             # full 1M empresas
//	eavt-load --demo-only                 # first-empresa probe
package main

import (
	"flag"
	"fmt"
	"os"

	"eavt-go/internal/client"
	"eavt-go/internal/loader"
)

func main() {
	n := flag.Int("n", 1_000_000, "number of empresas to load")
	dataDir := flag.String("data-dir", loader.DefaultDataDir, "receita zip directory")
	sock := flag.String("sock", "", "query server socket (default auto-detect)")
	batch := flag.Int("batch", 500, "ops batch size")
	demo := flag.Bool("demo-only", false, "run the first-empresa probe and exit")
	skipSimples := flag.Bool("skip-simples", false, "skip the Simples merge")
	skipEstabs := flag.Bool("skip-estabs", false, "skip Estabelecimentos0")
	skipSocios := flag.Bool("skip-socios", false, "skip Socios0")
	maxEstabs := flag.Int("max-estabs", 0, "stop estabs after N saved rows (0 = first batch)")
	maxSocios := flag.Int("max-socios", 0, "stop socios after N scanned rows (0 = unlimited)")
	flag.Parse()

	path := *sock
	if path == "" {
		path = client.DefaultSocketPath()
	}
	c, err := client.Dial(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: cannot connect to %s: %v\n", path, err)
		os.Exit(1)
	}
	defer c.Close()

	if *demo {
		if err := loader.Demo(c); err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		return
	}

	opts := loader.Opts{
		DataDir:     *dataDir,
		N:           *n,
		Batch:       *batch,
		SkipSimples: *skipSimples,
		SkipEstabs:  *skipEstabs,
		SkipSocios:  *skipSocios,
		MaxEstabs:   *maxEstabs,
		MaxSocios:   *maxSocios,
	}
	if err := loader.Load(c, opts); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
	if err := loader.Demo(c); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}
