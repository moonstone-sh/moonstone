# LuaRocks vs Moonstone benchmark

This is a disposable, Linux-only online benchmark for a shared, exact set of
LuaRocks package versions. Moonstone receives the same exact constraints that
LuaRocks receives as explicit install versions.

It deliberately compares two different user-facing setups:

| Case | What the timer measures |
| --- | --- |
| LuaRocks | Debian's system Lua 5.4 plus LuaRocks installing the pinned rocks into a fresh custom tree. |
| Moonstone | Moonstone provisioning a fresh project-local runtime and the pinned rocks into an empty Moonstone home. |

The image build installs `lua5.4`, LuaRocks, build tools, and builds Moonstone.
Those image-construction costs are **not** timed. Each measurement creates a
fresh `HOME`, cache directories, project directory, LuaRocks tree, and
Moonstone home; nothing is written to the host other than Docker image layers.
LuaRocks builds native rocks with Debian's C toolchain. Moonstone uses the
bundled Zig toolchain for the same work, matching its normal materialization
boundary.

## Suites

| Suite | Moonstone measurement | LuaRocks measurement |
| --- | --- | --- |
| `clean` | Empty Moonstone home: locked runtime, packages, lock, and project environment. | Empty custom rock tree using Debian's preinstalled Lua 5.4. |
| `dependencies` | Same as `clean`, but a runtime-only project prewarms Moonstone's runtime outside the timer. | Same custom-tree install; the system runtime is already provisioned. |
| `locked-replay` | Existing exact lock and CAS artifacts, with only `.moonstone/env` removed before `moon sync --locked --offline`. The timer stops after the environment replay; `moon run verify` runs afterward as mandatory correctness validation. | Not applicable: LuaRocks has no equivalent lock replay contract. |

`clean` is the default. Use `all` to run every suite.

Set `BENCHMARK_SHOW_LOGS=1` while diagnosing a run to print each timed
command's captured output and timing data after its result record. Normal runs
remain concise and retain the same NDJSON output.

## Run

From the Moonstone repository root:

```bash
docker build -f benchmarks/luarocks-vs-moonstone/Dockerfile \
  -t moonstone-luarocks-benchmark .

docker run --rm \
  -v "$PWD/.benchmark-results:/work/report" \
  -e BENCHMARK_RUNS=3 \
  -e BENCHMARK_SUITE=clean \
  -e MOONSTONE_BENCHMARK_JOBS=8 \
  moonstone-luarocks-benchmark
```

The benchmark prints one NDJSON record per measurement and a median wall-time
summary. The mounted report directory retains timing logs and
`results.ndjson` after `docker run --rm` exits. Increase `BENCHMARK_RUNS` when
comparing changes. Do not compare a single run as a release claim: public
registry latency, CDN state, and source build timing are intentionally included
and will vary.

The image defaults to a single-job `ReleaseFast` Moonstone build for throughput
benchmarking. Moonstone's current release workflows build `ReleaseSafe`, so a
benchmark that must match the published executable exactly should select it
explicitly. Both modes may require a Docker VM with more memory than a default
local Colima allocation:

```bash
docker build -f benchmarks/luarocks-vs-moonstone/Dockerfile \
  --build-arg MOONSTONE_OPTIMIZE=ReleaseSafe \
  -t moonstone-luarocks-benchmark .
```

## Scope and fairness

This is **not** a claim that the two tools have identical responsibilities.
LuaRocks receives a preinstalled system runtime. Moonstone intentionally
provisions a project-local locked runtime, dependency environment, and project
projection. The runner invokes the LuaRocks CLI through `lua5.4` explicitly,
so both sides target and execute their package-manager logic on Lua 5.4. The
resulting measurement answers a practical question:

> From an empty machine-like environment, how long does each supported setup
> take to make this project runnable?

Do not combine suite results: each describes a different product boundary.

## Disposal

`docker run --rm` removes the benchmark container after it exits. Remove the
image when you are done:

```bash
docker image rm moonstone-luarocks-benchmark
```
