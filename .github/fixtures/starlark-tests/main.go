// Runs a Starlark module together with its test file, using go.starlark.net (the interpreter
// family Kurtosis embeds) in its strict default dialect: no recursion, no while loops, no
// top-level control flow. The test file is appended to the module, so it calls the module's
// functions directly.
//
// Usage: go run . MODULE.star TEST.star
//
// Predeclared for tests:
//
//	json                 the starlark json module
//	try_call(fn, *args)  the fail() message of fn(*args), or "" when it succeeds
//	yaml_to_json(text)   text parsed with yaml.v3 (the parser behind Vouch's viper), as JSON
package main

import (
	stdjson "encoding/json"
	"fmt"
	"os"
	"strings"

	starlarkjson "go.starlark.net/lib/json"
	"go.starlark.net/starlark"
	"go.starlark.net/syntax"
	"gopkg.in/yaml.v3"
)

func tryCall(thread *starlark.Thread, _ *starlark.Builtin, args starlark.Tuple, _ []starlark.Tuple) (starlark.Value, error) {
	_, err := starlark.Call(thread, args[0], args[1:], nil)
	if err == nil {
		return starlark.String(""), nil
	}
	if evalErr, ok := err.(*starlark.EvalError); ok {
		return starlark.String(strings.TrimPrefix(evalErr.Msg, "fail: ")), nil
	}
	return nil, err
}

func yamlToJSON(_ *starlark.Thread, _ *starlark.Builtin, args starlark.Tuple, _ []starlark.Tuple) (starlark.Value, error) {
	text, ok := starlark.AsString(args[0])
	if !ok {
		return nil, fmt.Errorf("yaml_to_json: want a string")
	}
	var value any
	if err := yaml.Unmarshal([]byte(text), &value); err != nil {
		return nil, fmt.Errorf("yaml_to_json: %w", err)
	}
	out, err := stdjson.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("yaml_to_json: %w", err)
	}
	return starlark.String(out), nil
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: go run . MODULE.star TEST.star")
		os.Exit(2)
	}
	module, err := os.ReadFile(os.Args[1])
	check(err)
	test, err := os.ReadFile(os.Args[2])
	check(err)

	thread := &starlark.Thread{Name: "test", Print: func(_ *starlark.Thread, msg string) { fmt.Println(msg) }}
	predeclared := starlark.StringDict{
		"json":         starlarkjson.Module,
		"try_call":     starlark.NewBuiltin("try_call", tryCall),
		"yaml_to_json": starlark.NewBuiltin("yaml_to_json", yamlToJSON),
	}
	_, err = starlark.ExecFileOptions(&syntax.FileOptions{}, thread, os.Args[2], string(module)+"\n"+string(test), predeclared)
	if err != nil {
		if evalErr, ok := err.(*starlark.EvalError); ok {
			fmt.Fprintln(os.Stderr, evalErr.Backtrace())
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
	fmt.Println("ok")
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
