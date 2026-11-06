package main

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestFailedTurnIsInspectableButCommandRefusalFails(t *testing.T) {
	for _, test := range []struct {
		name           string
		response       map[string]any
		commandFailure bool
	}{
		{"failed turn", map[string]any{"state": "failed", "id": "turn-1", "error": "runner exited 7"}, false},
		{"command refused", map[string]any{"command_error": "agent already active"}, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			// Short socket paths also work on macOS with its small sockaddr_un limit.
			dir, err := os.MkdirTemp("/tmp", "atlas-rt-test-")
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.RemoveAll(dir) })
			listener, err := net.Listen("unix", filepath.Join(dir, "runtime.sock"))
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			served := make(chan error, 1)
			go func() {
				conn, err := listener.Accept()
				if err != nil {
					served <- err
					return
				}
				defer conn.Close()
				var command map[string]any
				if err = json.NewDecoder(conn).Decode(&command); err == nil {
					err = json.NewEncoder(conn).Encode(test.response)
				}
				served <- err
			}()
			result, err := request(dir, map[string]any{"command": "status"})
			if test.commandFailure {
				if err == nil {
					t.Fatal("command refusal must fail the invocation")
				}
			} else {
				if err != nil {
					t.Fatalf("failed turn must remain inspectable: %v", err)
				}
				if result["state"] != "failed" || result["error"] != "runner exited 7" || result["id"] != "turn-1" {
					t.Fatalf("failed-turn context was lost: %#v", result)
				}
			}
			if err := <-served; err != nil {
				t.Fatal(err)
			}
		})
	}
}
