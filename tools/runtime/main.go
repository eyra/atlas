// atlas-runtime is a client of the separate Elixir Runtime service.
package main

import (
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
	err = json.NewDecoder(io.LimitReader(conn, 1048576)).Decode(&reply)
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
		return nil, errors.New("use service start|status|stop, start --cwd PATH ASSIGNMENT, status, output, or stop")
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
		if err = flags.Parse(args[1:]); err != nil {
			return nil, err
		}
		if *sandbox != "read-only" && *sandbox != "workspace-write" {
			return nil, errors.New("sandbox must be read-only or workspace-write")
		}
		if *cwd == "" || flags.NArg() != 1 || strings.TrimSpace(flags.Arg(0)) == "" {
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
		command["sandbox"] = *sandbox
	case "status", "output", "stop":
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

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "--help" || os.Args[1] == "-h") {
		fmt.Println("atlas-runtime service start|status|stop\natlas-runtime start --cwd PATH [--sandbox read-only|workspace-write] \"assignment\"\natlas-runtime status|output|stop\nCodex uses its existing login. Sandbox defaults to read-only. One agent at a time.")
		return
	}
	result, err := execute(os.Args[1:])
	if err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"error": err.Error()})
		os.Exit(1)
	}
	json.NewEncoder(os.Stdout).Encode(result)
}
