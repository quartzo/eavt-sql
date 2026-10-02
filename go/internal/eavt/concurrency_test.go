package eavt

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// TestResolverConcurrent exercises concurrent reads (queries) against writes
// (WAL/schema bootstrap) on the resolver RWMutex.
func TestResolverConcurrent(t *testing.T) {
	r := NewResolver()
	var wg sync.WaitGroup
	stop := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		i := 0
		for {
			select {
			case <-stop:
				return
			default:
			}
			r.LoadUserAttr(fmt.Sprintf("ns/a%d", i%50), int64(100+i%50), DbTypeString, false, false, false)
			i++
		}
	}()
	for k := 0; k < 4; k++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				r.LookupAttr("ns/a1")
				r.IsIndexed(100)
				r.ValueTypeFor(100)
				r.AttrName(100)
				r.AttrsSnapshot()
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(stop)
	wg.Wait()
}
