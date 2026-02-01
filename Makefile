CC ?= gcc
CFLAGS ?= -O3 -std=c99

.PHONY: all octomark benchmark test clean

all: octomark

octomark: octomark.c
	$(CC) $(CFLAGS) octomark.c -o octomark

benchmark: benchmark.c octomark.c
	$(CC) $(CFLAGS) benchmark.c -o benchmark

test: test.c octomark.c
	$(CC) $(CFLAGS) test.c -o test_runner

clean:
	rm -f octomark benchmark test_runner
