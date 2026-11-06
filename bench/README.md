## Gateway benchmark

| Concurrent callers | Calls per second | Time per call |
| --- | --- | --- |
| 100 | 520,000–590,000 | 1.7–1.9 µs |
| 1,000 | 420,000–560,000 | 1.8–2.4 µs |
| 5,000 | 380,000–425,000 | 2.4–2.6 µs |

Gateway overhead per model call, from `mix run bench/gateway.exs` from the repository root: AMD Ryzen AI Max+ 395 (32
threads), Elixir 1.20, OTP 28, range of five runs.
