# Common tasks. `make start` fetches live data and opens the report in Chrome.
.PHONY: start test format

start:
	mix stats

test:
	mix test

format:
	mix format
