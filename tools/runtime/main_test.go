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

func TestExecuteRejectsInvalidPreferencesBeforeSocketRequest(t *testing.T) {
	t.Setenv("ATLAS_RUNTIME_HOME", t.TempDir())
	pair := []string{"preferences", "--preferred", "claude", "--fallback", "codex"}
	for _, test := range []struct {
		name string
		args []string
		want string
	}{
		{"positional", []string{"preferences", "claude"}, "does not accept positional arguments"},
		{"trailing positional", append(append([]string{}, pair...), "extra"), "does not accept positional arguments"},
		{"positional after separator", []string{"preferences", "--", "claude"}, "does not accept positional arguments"},
		{"unknown flag", []string{"preferences", "--model", "sonnet"}, "flag provided but not defined"},
		{"missing value", []string{"preferences", "--preferred"}, "flag needs an argument"},
		{"missing fallback", []string{"preferences", "--preferred", "claude"}, "use preferences --preferred"},
		{"missing preferred", []string{"preferences", "--fallback", "codex"}, "use preferences --preferred"},
		{"empty preferred", []string{"preferences", "--preferred=", "--fallback", "codex"}, "use preferences --preferred"},
		{"empty fallback", []string{"preferences", "--preferred", "claude", "--fallback="}, "use preferences --preferred"},
		{"unknown preferred", []string{"preferences", "--preferred", "other", "--fallback", "codex"}, "use preferences --preferred"},
		{"unknown fallback", []string{"preferences", "--preferred", "claude", "--fallback", "other"}, "use preferences --preferred"},
		{"reversed pair", []string{"preferences", "--preferred", "codex", "--fallback", "claude"}, "use preferences --preferred"},
		{"same backend", []string{"preferences", "--preferred", "claude", "--fallback", "claude"}, "use preferences --preferred"},
		{"preferred model only", []string{"preferences", "--preferred-model", "sonnet"}, "use preferences --preferred"},
		{"fallback model only", []string{"preferences", "--fallback-model", "gpt-5"}, "use preferences --preferred"},
		{"empty preferred model", append(append([]string{}, pair...), "--preferred-model="), "models must be nonempty"},
		{"blank preferred model", append(append([]string{}, pair...), "--preferred-model", " \t"), "models must be nonempty"},
		{"empty fallback model", append(append([]string{}, pair...), "--fallback-model="), "models must be nonempty"},
		{"blank fallback model", append(append([]string{}, pair...), "--fallback-model", "\n "), "models must be nonempty"},
		{"missing model value", append(append([]string{}, pair...), "--fallback-model"), "flag needs an argument"},
		{"empty reenable", []string{"preferences", "--reenable="}, "use preferences --reenable"},
		{"unknown reenable", []string{"preferences", "--reenable", "other"}, "use preferences --reenable"},
		{"codex reenable", []string{"preferences", "--reenable", "codex"}, "use preferences --reenable"},
		{"mixed pair", append(append([]string{}, pair...), "--reenable", "claude"), "use preferences --reenable"},
		{"mixed empty preferred", []string{"preferences", "--reenable", "claude", "--preferred="}, "use preferences --reenable"},
		{"mixed preferred model", []string{"preferences", "--reenable", "claude", "--preferred-model", "sonnet"}, "use preferences --reenable"},
		{"mixed empty fallback model", []string{"preferences", "--reenable", "claude", "--fallback-model="}, "use preferences --reenable"},
	} {
		t.Run(test.name, func(t *testing.T) {
			result, err := execute(test.args)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected argument refusal %q, got result %#v, error %v", test.want, result, err)
			}
			if result != nil {
				t.Fatalf("invalid request returned a result: %#v", result)
			}
		})
	}
}

func TestExecuteRejectsInvalidStartBackendBeforeSocketRequest(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ATLAS_RUNTIME_HOME", dir)
	for _, backend := range []string{"", " ", "other", "Claude", "codex,claude"} {
		t.Run("backend="+backend, func(t *testing.T) {
			result, err := execute([]string{"start", "--cwd", dir, "--backend=" + backend, "inspect files"})
			if err == nil || err.Error() != "backend must be codex or claude" || result != nil {
				t.Fatalf("expected backend refusal, got result %#v, error %v", result, err)
			}
		})
	}
}
