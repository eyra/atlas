// atlas-runtime is a client of the separate Elixir Runtime service.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Set at installation with -ldflags '-X main.repoRoot=...'.
var repoRoot string

func home() (string, error) {
	if value := os.Getenv("ATLAS_RUNTIME_HOME"); value != "" {
		return filepath.Abs(value)
	}
	user, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(user, ".local", "state", "atlas-runtime"), nil
}

func request(dir string, command map[string]any) (map[string]any, error) {
	conn, err := net.DialTimeout("unix", filepath.Join(dir, "runtime.sock"), time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	if err = json.NewEncoder(conn).Encode(command); err != nil {
		return nil, err
	}
	var reply map[string]any
	var response io.Reader = conn
	// History can span many turns; retain the existing cap for individual replies.
	if command["command"] != "turns" {
		response = io.LimitReader(conn, 1048576)
	}
	err = json.NewDecoder(response).Decode(&reply)
	if err == nil && reply["command_error"] != nil {
		err = fmt.Errorf("%v", reply["command_error"])
	}
	return reply, err
}

func absent(err error) bool {
	return errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED)
}

func environment(dir string) []string {
	result := []string{}
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "ATLAS_") && !strings.HasPrefix(item, "MIX_ENV=") &&
			!strings.HasPrefix(item, "MIX_BUILD_PATH=") && !strings.HasPrefix(item, "ELIXIR_ERL_OPTIONS=") {
			result = append(result, item)
		}
	}
	return append(result, "MIX_ENV=test", "MIX_BUILD_PATH="+filepath.Join(dir, "build"), "ELIXIR_ERL_OPTIONS=+S 2:2")
}

func service(dir, action string) (map[string]any, error) {
	if action == "status" {
		result, err := request(dir, map[string]any{"command": "service-status"})
		if absent(err) {
			return map[string]any{"service": "stopped"}, nil
		}
		return result, err
	}
	if action != "start" && action != "stop" {
		return nil, errors.New("use service start|status|stop")
	}
	lock, err := os.OpenFile(filepath.Join(dir, "service.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return nil, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	result, err := request(dir, map[string]any{"command": "service-status"})
	if action == "stop" {
		if absent(err) {
			return map[string]any{"service": "stopped"}, nil
		}
		if err != nil {
			return nil, err
		}
		result, err = request(dir, map[string]any{"command": "service-stop"})
		if err != nil {
			return nil, err
		}
		for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); {
			conn, dialErr := net.DialTimeout("unix", filepath.Join(dir, "runtime.sock"), time.Second)
			if absent(dialErr) {
				return map[string]any{"service": "stopped", "agent": result["agent"]}, nil
			}
			if conn != nil {
				conn.Close()
			}
			time.Sleep(100 * time.Millisecond)
		}
		return nil, errors.New("service stop acknowledged but exit not confirmed")
	}
	if err == nil {
		return result, nil
	}
	if !absent(err) {
		return nil, fmt.Errorf("existing service is not responding: %w", err)
	}
	if repoRoot == "" {
		return nil, errors.New("CLI was not built with the Atlas checkout location")
	}
	// Only remove a socket when no process is listening. Never signal saved PIDs.
	if err = os.Remove(filepath.Join(dir, "runtime.sock")); err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	build := exec.Command("mix", "compile", "--warnings-as-errors")
	build.Dir = filepath.Join(repoRoot, "beam", "apps", "atlas_runtime")
	build.Env = environment(dir)
	build.Stdout = os.Stderr
	build.Stderr = os.Stderr
	if err = build.Run(); err != nil {
		return nil, fmt.Errorf("Runtime build: %w", err)
	}
	log, err := os.OpenFile(filepath.Join(dir, "service.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return nil, err
	}
	defer log.Close()
	cmd := exec.Command("mix", "run", "--no-start", "--no-compile", "--no-deps-check",
		filepath.Join(repoRoot, "tools/runtime/service.exs"), dir)
	cmd.Dir = filepath.Join(repoRoot, "beam", "apps", "atlas_runtime")
	cmd.Env = environment(dir)
	cmd.Stdout = log
	cmd.Stderr = log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err = cmd.Start(); err != nil {
		return nil, err
	}
	ended := make(chan error, 1)
	go func() { ended <- cmd.Wait() }()
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); {
		select {
		case exit := <-ended:
			return nil, fmt.Errorf("Runtime exited (%v); inspect %s", exit, filepath.Join(dir, "service.log"))
		default:
		}
		result, err = request(dir, map[string]any{"command": "service-status"})
		if err == nil {
			return result, nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	// This is the child started by this invocation, not a PID read from disk.
	cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-ended:
	case <-time.After(5 * time.Second):
		cmd.Process.Kill()
		<-ended
	}
	return nil, fmt.Errorf("Runtime startup timed out; inspect %s", filepath.Join(dir, "service.log"))
}

func execute(args []string) (map[string]any, error) {
	if len(args) == 0 {
		return nil, errors.New("use service start|status|stop, start --cwd PATH ASSIGNMENT, continue ASSIGNMENT, preferences, status, output, or stop")
	}
	dir, err := home()
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	// Mix derives relative priv symlinks from MIX_BUILD_PATH. Resolve directory
	// aliases (notably /tmp -> /private/tmp on macOS) before building or launching.
	dir, err = filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, err
	}
	if err = os.Chmod(dir, 0700); err != nil {
		return nil, err
	}
	if args[0] == "service" {
		if len(args) != 2 {
			return nil, errors.New("use service start|status|stop")
		}
		return service(dir, args[1])
	}
	command := map[string]any{"command": args[0]}
	switch args[0] {
	case "start":
		flags := flag.NewFlagSet("start", flag.ContinueOnError)
		cwd := flags.String("cwd", "", "existing working directory")
		sandbox := flags.String("sandbox", "read-only", "read-only or workspace-write")
		permissions := flags.String("permissions", "", "explicit dedicated-repository Git/GitHub scope")
		repository := flags.String("repo", "", "GitHub HTTPS repository to provision")
		branch := flags.String("branch", "", "new task branch based on freshly fetched develop")
		backend := flags.String("backend", "", "explicit codex or claude; omitted uses preferences")
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		backendSet := false
		flags.Visit(func(f *flag.Flag) {
			if f.Name == "backend" {
				backendSet = true
			}
		})
		if backendSet {
			if *backend != "codex" && *backend != "claude" {
				return nil, errors.New("backend must be codex or claude")
			}
			command["backend"] = *backend
		}
		if *sandbox != "read-only" && *sandbox != "workspace-write" {
			return nil, errors.New("sandbox must be read-only or workspace-write")
		}
		if *permissions != "" && *permissions != "dedicated-repository" {
			return nil, errors.New("unknown permission profile")
		}
		conflict := false
		flags.Visit(func(f *flag.Flag) {
			if f.Name == "sandbox" && *permissions != "" {
				conflict = true
			}
		})
		if conflict {
			return nil, errors.New("permissions cannot be combined with sandbox")
		}
		if flags.NArg() != 1 || strings.TrimSpace(flags.Arg(0)) == "" {
			return nil, errors.New("start requires one nonempty assignment")
		}
		if *repository != "" || *branch != "" {
			if *repository == "" || *branch == "" || *cwd != "" || *permissions != "dedicated-repository" {
				return nil, errors.New("use start --repo URL --branch NEW_BRANCH --permissions dedicated-repository \"assignment\" without --cwd")
			}
			command["repository"] = *repository
			command["branch"] = *branch
			command["permissions"] = *permissions
			command["assignment"] = flags.Arg(0)
			break
		}
		if *cwd == "" {
			return nil, errors.New("use start --cwd PATH \"assignment\"")
		}
		path, err := filepath.Abs(*cwd)
		if err != nil {
			return nil, err
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			return nil, errors.New("cwd is not a directory")
		}
		command["cwd"] = path
		command["assignment"] = flags.Arg(0)
		if *permissions == "" {
			command["sandbox"] = *sandbox
		} else {
			command["permissions"] = *permissions
		}
	case "preferences":
		flags := flag.NewFlagSet("preferences", flag.ContinueOnError)
		preferred := flags.String("preferred", "", "preferred backend: claude")
		fallback := flags.String("fallback", "", "fallback backend: codex")
		preferredModel := flags.String("preferred-model", "", "optional Claude model")
		fallbackModel := flags.String("fallback-model", "", "optional Codex model")
		reenable := flags.String("reenable", "", "reenable backend: claude")
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if flags.NArg() != 0 {
			return nil, errors.New("preferences does not accept positional arguments")
		}
		supplied := map[string]bool{}
		flags.Visit(func(f *flag.Flag) { supplied[f.Name] = true })
		if supplied["reenable"] {
			if len(supplied) != 1 || *reenable != "claude" {
				return nil, errors.New("use preferences --reenable claude without other flags")
			}
			command["reenable"] = *reenable
		} else if len(supplied) != 0 {
			if *preferred != "claude" || *fallback != "codex" {
				return nil, errors.New("use preferences --preferred claude --fallback codex [--preferred-model MODEL] [--fallback-model MODEL]")
			}
			for _, selection := range []struct {
				name  string
				model string
			}{
				{"preferred", *preferredModel},
				{"fallback", *fallbackModel},
			} {
				var model any
				if supplied[selection.name+"-model"] {
					if strings.TrimSpace(selection.model) == "" {
						return nil, errors.New("explicit preference models must be nonempty")
					}
					model = selection.model
				}
				backend := *preferred
				if selection.name == "fallback" {
					backend = *fallback
				}
				command[selection.name] = map[string]any{"backend": backend, "model": model}
			}
		}
	case "continue":
		if len(args) == 2 && strings.TrimSpace(args[1]) != "" {
			command["assignment"] = args[1]
		} else if len(args) == 4 && args[1] == "--turn" && args[2] != "" && strings.TrimSpace(args[3]) != "" {
			command["turn_id"] = args[2]
			command["assignment"] = args[3]
		} else {
			return nil, errors.New("use continue [--turn TURN_ID] \"assignment\"; working directory and sandbox cannot change")
		}
	case "output":
		if len(args) == 3 && args[1] == "--turn" && args[2] != "" {
			command["turn_id"] = args[2]
		} else if len(args) != 1 {
			return nil, errors.New("use output, output --follow, or output --turn TURN_ID")
		}
	case "status", "turns", "stop":
		if len(args) != 1 {
			return nil, errors.New("unexpected arguments")
		}
	default:
		return nil, errors.New("unknown command")
	}
	result, err := request(dir, command)
	if absent(err) {
		return nil, errors.New("Runtime service is stopped; run atlas-runtime service start")
	}
	return result, err
}

// eventReader retains incomplete records across EOF while the native log grows.
type eventReader struct {
	reader  *bufio.Reader
	pending []byte
	turnID  string
	encoder *json.Encoder
}

func (events *eventReader) drain(final bool) error {
	for {
		line, err := events.reader.ReadBytes('\n')
		if len(events.pending) == 0 {
			events.pending = line
		} else {
			events.pending = append(events.pending, line...)
		}
		if err != nil && err != io.EOF {
			return err
		}
		if len(events.pending) != 0 && (err == nil || final) {
			if !json.Valid(events.pending) {
				return errors.New("native output contains an invalid or truncated JSON event")
			}
			if writeErr := events.encoder.Encode(map[string]any{
				"type": "event", "turn_id": events.turnID, "event": json.RawMessage(events.pending),
			}); writeErr != nil {
				return writeErr
			}
			events.pending = nil
		}
		if err == io.EOF {
			return nil
		}
	}
}

func followOutput(out io.Writer) error {
	current, err := execute([]string{"status"})
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(out)
	if current["state"] == "idle" {
		return encoder.Encode(map[string]any{"type": "result", "turn": current})
	}
	id, idOK := current["id"].(string)
	folder, folderOK := current["artifacts"].(string)
	if !idOK || id == "" || !folderOK || folder == "" {
		return errors.New("Runtime did not provide a turn ID and artifact directory")
	}
	if err = encoder.Encode(map[string]any{"type": "status", "turn": current}); err != nil {
		return err
	}
	var file *os.File
	defer func() {
		if file != nil {
			file.Close()
		}
	}()
	events := eventReader{turnID: id, encoder: encoder}
	for {
		final := current["state"] != "running"
		if file == nil {
			file, err = os.Open(filepath.Join(folder, "stream.jsonl"))
			if err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			if file != nil {
				events.reader = bufio.NewReader(file)
			}
		}
		if file != nil {
			if err = events.drain(final); err != nil {
				return err
			}
		}
		if final {
			answer, readErr := os.ReadFile(filepath.Join(folder, "answer.txt"))
			if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
				return readErr
			}
			current["answer"] = nil
			if readErr == nil {
				current["answer"] = string(answer)
			}
			return encoder.Encode(map[string]any{"type": "result", "turn": current})
		}
		time.Sleep(200 * time.Millisecond)
		current, err = execute([]string{"status"})
		if err != nil {
			return err
		}
		if current["id"] != id {
			return errors.New("current turn changed while following output; refusing to switch turns")
		}
	}
}

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		fmt.Println("atlas-runtime service start|status|stop\natlas-runtime start --cwd PATH [--backend codex|claude] [--sandbox read-only|workspace-write | --permissions dedicated-repository] \"assignment\"\natlas-runtime start --repo https://github.com/OWNER/REPO.git --branch NEW_BRANCH [--backend codex|claude] --permissions dedicated-repository \"assignment\"\natlas-runtime continue [--turn TURN_ID] \"next assignment\"\natlas-runtime preferences\natlas-runtime preferences --preferred claude --fallback codex [--preferred-model MODEL] [--fallback-model MODEL]\natlas-runtime preferences --reenable claude\natlas-runtime status|turns|output|stop\natlas-runtime output --follow\natlas-runtime output --turn TURN_ID\nStart uses configured preferences when --backend is omitted; without preferences it uses Codex. An explicit --backend never falls back. Configured models apply to the selected backend. Preferences inspects configuration and eligibility; --reenable claude clears its quota block. Claude defaults to read-only; explicit dedicated-repository uses native sandboxed Bash in an independent repository outside system temp roots. Both use their official CLI login. Managed provisioning requires the installed Codex sandbox for Git preparation, including for Claude. Claude workspace-write is refused. Continue requires a successful saved native session and retains its backend, model and scope. One agent at a time.")
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "output" && os.Args[2] == "--follow" {
		if err := followOutput(os.Stdout); err != nil {
			json.NewEncoder(os.Stdout).Encode(map[string]any{"error": err.Error()})
			os.Exit(1)
		}
		return
	}
	result, err := execute(os.Args[1:])
	if err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	json.NewEncoder(os.Stdout).Encode(result)
}
