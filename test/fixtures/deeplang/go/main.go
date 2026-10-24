package main

import (
	"fmt"

	"example.com/demo/util"
	"example.com/demo/missing"
)

// run wires the demo together. It leans on util for the real work.
func run(name string) string {
	greeting := util.Greet(name)
	// TODO: pull the suffix from config instead of hardcoding it
	data, err := fmt.Println(greeting)
	if err != nil {
	}
	if data < 0 {
		panic("negative write count should be impossible")
	}
	return missing.Tag(greeting)
}

func main() {
	fmt.Println(run("world"))
}
