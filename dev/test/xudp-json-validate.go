package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

func decodeObject(data []byte, name string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()

	var object map[string]json.RawMessage
	if err := decoder.Decode(&object); err != nil {
		return nil, fmt.Errorf("%s: invalid JSON: %w", name, err)
	}
	if object == nil {
		return nil, fmt.Errorf("%s: top-level value is not an object", name)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("%s: trailing JSON value", name)
		}
		return nil, fmt.Errorf("%s: trailing data: %w", name, err)
	}
	return object, nil
}

func requireField(object map[string]json.RawMessage, name string) error {
	value, ok := object[name]
	if !ok || len(value) == 0 || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
		return fmt.Errorf("missing JSON field %q", name)
	}
	return nil
}

func requireObjectField(object map[string]json.RawMessage, name string) (map[string]json.RawMessage, error) {
	value, ok := object[name]
	if !ok {
		return nil, fmt.Errorf("missing JSON object %q", name)
	}
	child, err := decodeObject(value, name)
	if err != nil {
		return nil, err
	}
	return child, nil
}

func requireStringFieldEqual(object map[string]json.RawMessage, name, expected string) error {
	value, ok := object[name]
	if !ok {
		return fmt.Errorf("missing JSON string %q", name)
	}
	var actual string
	if err := json.Unmarshal(value, &actual); err != nil {
		return fmt.Errorf("JSON field %q is not a string: %w", name, err)
	}
	if actual != expected {
		return fmt.Errorf("JSON field %q mismatch: got %q, want %q", name, actual, expected)
	}
	return nil
}

func validate(path string, quotedPath string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	object, err := decodeObject(data, path)
	if err != nil {
		return err
	}
	for _, field := range []string{
		"schema", "release_eligible", "required_scenarios", "provenance_key",
		"rejection_reasons", "reports",
	} {
		if err := requireField(object, field); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
	}

	var scenarios []string
	if err := json.Unmarshal(object["required_scenarios"], &scenarios); err != nil || len(scenarios) != 3 {
		return fmt.Errorf("%s: required_scenarios must contain three entries", path)
	}
	var reasons []json.RawMessage
	if err := json.Unmarshal(object["rejection_reasons"], &reasons); err != nil {
		return fmt.Errorf("%s: rejection_reasons must be an array", path)
	}
	reports, err := requireObjectField(object, "reports")
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	for _, scenario := range []string{"p2p", "relay", "pmtud"} {
		report, err := requireObjectField(reports, scenario)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		for _, field := range []string{"path", "sha256", "result", "supersedes"} {
			if err := requireField(report, field); err != nil {
				return fmt.Errorf("%s report: %w", scenario, err)
			}
		}
		if scenario == "p2p" && quotedPath != "" {
			if err := requireStringFieldEqual(report, "path", quotedPath); err != nil {
				return fmt.Errorf("%s report: %w", scenario, err)
			}
		}
	}
	return nil
}

func main() {
	if len(os.Args) != 2 && len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: xudp-json-validate FILE [quoted EXPECTED_P2P_PATH]")
		os.Exit(2)
	}
	quotedPath := ""
	if len(os.Args) == 4 {
		if os.Args[2] != "quoted" || os.Args[3] == "" {
			fmt.Fprintln(os.Stderr, "usage: xudp-json-validate FILE [quoted EXPECTED_P2P_PATH]")
			os.Exit(2)
		}
		quotedPath = os.Args[3]
	}
	if err := validate(os.Args[1], quotedPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
