//go:build !linux

package main

import "os/exec"

func configureProcess(cmd *exec.Cmd) {}
