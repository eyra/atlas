package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
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

func TestFollowRetainsPartialUTF8RecordsAcrossEOF(t *testing.T) {
	var source, output bytes.Buffer
	reader := eventReader{
		reader: bufio.NewReader(&source), turnID: "turn-original", encoder: json.NewEncoder(&output),
	}
	first := []byte("{\"text\":\"🙂\"}\n")
	cut := bytes.Index(first, []byte("🙂")) + 1
	source.Write(first[:cut])
	if err := reader.drain(false); err != nil {
		t.Fatal(err)
	}
	if output.Len() != 0 {
		t.Fatal("incomplete event was emitted")
	}
	source.Write(first[cut:])
	source.WriteString(`{"text":"final without newline"}`)
	if err := reader.drain(false); err != nil {
		t.Fatal(err)
	}
	if err := reader.drain(true); err != nil {
		t.Fatal(err)
	}
	if err := reader.drain(true); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(&output)
	for _, want := range []string{"🙂", "final without newline"} {
		var row struct {
			Type   string                `json:"type"`
			TurnID string                `json:"turn_id"`
			Event  struct{ Text string } `json:"event"`
		}
		if err := decoder.Decode(&row); err != nil {
			t.Fatal(err)
		}
		if row.Type != "event" || row.TurnID != "turn-original" || row.Event.Text != want {
			t.Fatalf("event changed or was duplicated: %+v", row)
		}
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		t.Fatalf("expected exactly two events, got %v: %v", extra, err)
	}
}

func TestFollowRejectsTruncatedFinalRecord(t *testing.T) {
	var output bytes.Buffer
	reader := eventReader{
		reader: bufio.NewReader(strings.NewReader(`{"text":`)),
		turnID: "turn-original", encoder: json.NewEncoder(&output),
	}
	if err := reader.drain(true); err == nil {
		t.Fatal("truncated final event must fail, not silently disappear")
	}
	if output.Len() != 0 {
		t.Fatal("invalid event was emitted")
	}
}
