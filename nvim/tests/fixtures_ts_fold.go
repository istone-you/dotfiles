package main

func Fixture(values []int) int {
	total := 0
	for _, v := range values {
		total += v
	}
	return total
}
