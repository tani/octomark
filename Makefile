CC ?= gcc
CFLAGS ?= -O3 -std=c99

.PHONY: all octomark benchmark test clean

all: octomark

octomark: src/octomark.c
	$(CC) $(CFLAGS) src/octomark.c -o octomark

benchmark: benchmark/benchmark.c src/octomark.c
	$(CC) $(CFLAGS) benchmark/benchmark.c -o benchmark/benchmark

test: test/test.c src/octomark.c
	$(CC) $(CFLAGS) test/test.c -o test/test

clean:
	rm -f octomark benchmark/benchmark test/test
