# Dish Mac frame-path bench

`DishBench` (`Sources/DishBench`) times the Mac client's frame path with the production objects in their
thread roles, and counts every lock each role takes. `.github/workflows/measurements.yml` runs it on every
release and attaches the record to the release. This file is the method and the record.

## What is timed

A pad's report travels, on one thread, from GameController's handler queue (`com.tinkernorth.dish.input`)
through the pad's gate, `GamepadInputProcessor.publish`, the routing table, the connection's client
reference and `SatelliteClient.sendEncrypted` to `sendto`; a Direct pad's report makes the same trip from
IOKit's input-report callback on the reader's thread. The bench drives exactly those objects:
`FramePathRig` (`Sources/DishEngine/Measurement`) wires the processor, the routing table, a
`WifiConnection` and its `SatelliteClient` the way `AppModel` wires them, with the client's receive loop,
heartbeat and alive tick running, and routes the return paths to counters where a pad would be actuated.

The satellite is `LoopbackSatellite`, a raw UDP socket on 127.0.0.1 and one thread: it opens every uplink
datagram with the session key, stamps it after the decrypt, answers each heartbeat with its ack and sends
rumble and light-bar commands back to the client's port. Its own locks are untracked.

**Latency** is the satellite's stamp minus the publish stamp. A pad on the input queue is stamped inside
its queue block, just before the gate, where `pushReport` starts; GameController's own sampling of the
pad (fifteen key-path reads into a struct) is not part of it. The Direct pad is stamped just before
IOKit's callback. Both clocks are `CLOCK_UPTIME_RAW`. Each report carries a 16-bit sequence, in the right
stick's X on the input queue and on the Direct pad's right stick (low byte on X, high on Y, raw values just
past the dead zone that the Switch decoder's own scaling keeps apart), and the satellite's arrivals are
matched to their send stamps through it, across the sequence's wrap.

## Scenarios

| scenario | runs |
| --- | --- |
| S1 | pad A on the input queue at `--rate` (1000 Hz) |
| S2 | S1 and pad B at 250 Hz on the same serial queue, as GameController shares one |
| S3 | S2 and the main actor refreshing the routing table every 100 ms, as `AppModel.refreshRouting` does, and reading the tally every second |
| S4 | S3 and the satellite sending 100 rumble and 10 light-bar commands a second into the real receive path |
| S5 | S4 and the 2 s heartbeat and microphone packets from the capture queue at `--mic-hz` (50; also run at 1000) |
| S6 | a Direct Switch Pro pad at 1000 Hz on a HidReader-role thread, input and motion in every report |

S6 is a Switch Pro pad because the Mac reads only Nintendo pads and pads macOS does not support directly:
there is no DualSense Direct decoder. Its 0x30 reports carry input, three IMU frames and the battery, so
every report publishes input and the processor admits motion at its 250 Hz cap. The main actor's refresh
in S3 to S5 sleeps with `Task.sleep`, which the runner's timer stretched to 140 to 180 ms (17 to 21
refreshes in a 3 s rep).

## Pacing

Every stream runs to absolute deadlines: frame `k` is due `k` periods after the common start, whatever
happened to frame `k - 1`. A feeder that only hands frames on (the pads' pacers, which dispatch onto the
input queue, the satellite's rumble, the microphone) asks for a time-constraint policy (half its period,
at most half a millisecond, to compute in) and waits with `mach_wait_until` to within a spin window of
each deadline, then spins. The window comes from timing 30 waits of 2 ms on such a thread at start-up: the
90th percentile of how late they woke plus 100 us, between 100 us and a millisecond. The Direct pad's
thread is the reader's own, runs the frame path itself and stays unconstrained, as the reader is; it spins
the last millisecond before each report, which at 1000 Hz is all of it.

The constraint is there because of the runner. On the `macos-26` image a 2 ms sleep on an ordinary thread
woke 7.75 ms or more late at the 90th percentile, so the rumble and microphone feeders ran five to eight
milliseconds late, and a window wide enough to spin through that kept the feeders spinning on two of the
three cores, next to the path under test. Time-constrained waits woke 21, 268, 1027, 1043, 1052 and
1071 us late at the 90th percentile on six runs: the timer varies with the host and the moment, so the
window is measured on every run and recorded in the JSON (`spinUs`, `timerLateP90Us`).

## Reps and figures

Each scenario runs a 0.5 s warm-up that is thrown away and then `--reps` reps (3) of `--secs` seconds (3).
The reported rep is the one whose pad A p99.9 is the median. Per pad: `frames` fed, `p50`, `p99`, `p99.9`
and `max` in microseconds, `over 1 ms`, `longest gap` between two arrivals in milliseconds,
`datagrams/report` (every uplink datagram naming the pad, input, motion, battery and microphone, over the
reports fed; 1.00 for a pad on the input queue, about 1.2 for the Direct pad) and `drops` (fed but never
arrived).

The LOCK_STATS build (`-Xswiftc -DLOCK_STATS`) also prints, for the reported rep of every scenario, every
lock and role that took it: acquisitions, contended acquisitions, the longest and the 99th-percentile wait
and hold. Its bookkeeping costs a few clock reads per lock, so latency comes from the plain build and only
the lock counts from this one. `--json` writes the settings, the machine and every rep; `--csv` every rep's
rows. `--smoke` runs every scenario once for 0.2 s with no warm-up; its exit status is the harness's own
accounting (every pad's reports arrived, rumble reached the actuators, no feeder sent a frame before its
deadline), never a latency. A feeder whose median frame left more than a millisecond late is printed as a
note: on a shared runner that is the host's timer and load. macOS CI runs the smoke on both builds.

```sh
swift build -c release --product DishBench
.build/release/DishBench --json plain.json --csv plain.csv
.build/release/DishBench --only S5 --mic-hz 1000 --json plain-mic1000.json
swift build -c release --product DishBench -Xswiftc -DLOCK_STATS
.build/release/DishBench --json lockstats.json
.build/release/DishBench --only S5 --mic-hz 1000 --json lockstats-mic1000.json
.build/release/DishBench report --input-dir . --output-dir out --version dev
```

## Lock laws

Every lock the frame and receive paths take is a `TrackedLock` with an `area.thing` name, holding the
primitive the call site took before (the same inline `os_unfair_lock`, or the same `NSLock`) and, in the
plain build, nothing else. Each queue and thread on those paths takes its `ThreadRole` (Input, HidReader,
Receive, Heartbeat, Main, AudioDecode, AudioCapture, MoonlightUdp, Other) where it is made. `LockLawTests`
runs the production objects in their roles for about two and a half seconds and compares, per role, the
locks taken with a list: Input, HidReader and Receive, the locks held across a blocking call, and the
locks taken inside another, plus a check that the nesting has no cycle. Every entry today is debt; a lock
that appears fails the test, and so does a listed lock no longer taken until its entry is deleted.

## Release measurements

`measurements.yml` runs on pull requests that touch `Sources/` or the lock laws, by hand, and from
`release.yml` as the `measurements` job after the hardened bundle; `publish` needs it and ships its two
files beside the app. One `macos-26` job builds the bench plain and with lock statistics, runs the lock
laws, fetches the latest release's `measurements-*.json`, runs each build over every scenario and once
more with `--only S5 --mic-hz 1000`, and has `DishBench report` write `measurements-<version>.md` (the job
summary) and `measurements-<version>.json`; both are the `measurements` artifact and every rep is
`measurements-raw`.

- **Lock gate (reported, not enforced).** The Input, HidReader and Receive roles take no lock in any
  lock-stats run. It fails today; until the optimisation PR adds `--enforce-lock-gate`, the summary
  reports it and the job passes. A lock-stats run that recorded no lock cannot pass.
- **Trend (warnings only).** A pad's p99.9 or max more than twice the previous release's and over 100 us
  above it is a `::warning::`; no earlier release carrying measurements skips it.

`gh workflow run measurements.yml` dispatches it once the workflow is on main.

## Before: the 2.5.0 baseline

The code as release 1.1.0 left it (`d2364e4`) with this tooling on top; in the plain build every lock is the
primitive it was. Measured by `measurements.yml` with the label `before-2.5.0`, run
[41389797848](https://github.com/TinkerNorth/dish-mac/actions/runs/41389797848) on commit `4f2898c`,
called from a one-off workflow because `gh workflow run measurements.yml` refuses a workflow that is not yet
on main. Runner: GitHub Actions `macos-26`, Apple M1 (Virtual), VirtualMac2,1, 3 cores, 7.0 GB, macOS 26.6.2
(25G83). Time-constrained waits woke 268 us late at the 90th percentile in the plain run, so its pacers
spun 368 us, and 1043 to 1071 us in the other three, so theirs spun 1000 us. Every pacer of every rep kept
its deadlines: no frame early, and every median frame within 14 us of its deadline. The commands, as the
workflow ran them:

```sh
swift build --configuration release --product DishBench
cp .build/release/DishBench bench/DishBench-plain
swift build --configuration release --product DishBench -Xswiftc -DLOCK_STATS
cp .build/release/DishBench bench/DishBench-lockstats
swift build --build-tests -Xswiftc -DLOCK_STATS
swift test --skip-build --filter LockLawTests
for build in plain lockstats; do
  bench/DishBench-$build --json measurements-raw/$build.json --csv measurements-raw/$build.csv
  bench/DishBench-$build --only S5 --mic-hz 1000 --json measurements-raw/$build-mic1000.json
done
bench/DishBench-plain report --input-dir measurements-raw --output-dir measurements --version before-2.5.0 \
  --previous-dir previous-measurements --commit 4f2898ce915c4a2cfbd68c8851dfff475b0e1887
```

### Latency, plain build

The reported rep of each scenario. Latencies in microseconds; `longest gap` in milliseconds.

| run | scenario | pad | source | rate Hz | frames | p50 us | p99 us | p99.9 us | max us | over 1 ms | longest gap ms | datagrams/report | drops |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| plain | S1 | A | Input | 1000 | 3000 | 108.4 | 633.6 | 1944.0 | 3969.6 | 11 | 5.878 | 1.00 | 0 |
| plain | S2 | A | Input | 1000 | 3000 | 122.7 | 754.0 | 1814.0 | 4161.7 | 21 | 7.018 | 1.00 | 0 |
| plain | S2 | B | Input | 250 | 750 | 111.8 | 1120.1 | 4807.2 | 4807.2 | 11 | 8.849 | 1.00 | 0 |
| plain | S3 | A | Input | 1000 | 3000 | 95.9 | 683.1 | 3862.0 | 6922.3 | 20 | 8.118 | 1.00 | 0 |
| plain | S3 | B | Input | 250 | 750 | 96.1 | 440.6 | 1658.8 | 1658.8 | 3 | 12.117 | 1.00 | 0 |
| plain | S4 | A | Input | 1000 | 3000 | 113.0 | 597.0 | 3312.8 | 6743.8 | 15 | 26.288 | 1.00 | 0 |
| plain | S4 | B | Input | 250 | 750 | 103.5 | 773.5 | 3868.7 | 3868.7 | 5 | 27.643 | 1.00 | 0 |
| plain | S5 | A | Input | 1000 | 3000 | 105.2 | 375.1 | 1962.0 | 3208.7 | 14 | 7.431 | 1.05 | 0 |
| plain | S5 | B | Input | 250 | 750 | 103.9 | 503.1 | 5239.9 | 5239.9 | 5 | 9.959 | 1.00 | 0 |
| plain | S6 | A | HidReader | 1000 | 3000 | 107.8 | 1135.1 | 3123.1 | 13439.3 | 36 | 14.299 | 1.22 | 0 |
| plain-mic1000 | S5 | A | Input | 1000 | 3000 | 97.5 | 2018.3 | 5752.6 | 7452.8 | 81 | 24.445 | 2.00 | 0 |
| plain-mic1000 | S5 | B | Input | 250 | 750 | 91.9 | 1731.2 | 5779.0 | 5779.0 | 18 | 25.379 | 1.00 | 0 |

The median holds at 79 to 181 us in every rep of every scenario; the tail does not. Across the three reps
of one scenario pad A's p99.9 ran as far apart as 7.9, 3.3 and 1.0 ms (S4), and the `--mic-hz 1000` run's
third rep sent 313 of its 3000 frames over a millisecond. Every rumble (300 a rep) and light-bar command
(30) reached the actuators, and no report was dropped.

### Locks, lock-stats build

Every report on the input queue takes 12 lock acquisitions on the Input role (11 locks, the send lock
twice: once to see that the socket is open, once around `sendto`); a Direct report about 15.7 on the
HidReader role; each rumble datagram 7 on the Receive role. `sendto` runs under `satellite.send` on every
send, and no lock is taken inside another. The lock gate fails, as it must today: 120 lock and role pairs
on the gated roles across the lock-stats runs. Below, the gated roles' rows, every scenario's reported rep
merged (acquisitions and contended summed, the worst wait and hold kept); the run's job summary has every
role.

| lock | role | acquisitions | contended | max wait us | p99 wait us | max hold us | p99 hold us |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| connection.client | Input | 18000 | 2 | 151.3 | 0.1 | 384.8 | 1.0 |
| input.gate | Input | 18000 | 0 | 119.5 | 0.3 | 126.1 | 1.0 |
| input.lastInputMs | Input | 18000 | 0 | 33.8 | 0.3 | 20.9 | 0.1 |
| input.processor | Input | 18000 | 0 | 830.1 | 2.0 | 365.0 | 4.1 |
| input.reportSender | Input | 18000 | 0 | 12.1 | 0.1 | 70.5 | 0.5 |
| input.reportTap | Input | 18000 | 0 | 244.6 | 0.1 | 39.9 | 0.3 |
| input.tally | Input | 18000 | 0 | 8.3 | 0.1 | 259.6 | 1.0 |
| routing.sent | Input | 18000 | 0 | 116.0 | 0.1 | 56.4 | 0.1 |
| routing.table | Input | 18000 | 10 | 13.4 | 0.3 | 138.7 | 2.0 |
| satellite.params | Input | 18000 | 8 | 72.9 | 0.1 | 183.4 | 1.0 |
| satellite.send | Input | 36000 | 62 | 293.0 | 1.0 | 4654.0 | 131.1 |
| connection.client | HidReader | 3624 | 0 | 7.2 | 0.1 | 0.8 | 0.5 |
| direct.tally | HidReader | 3000 | 0 | 3.9 | 0.5 | 21.8 | 0.5 |
| input.gate | HidReader | 3000 | 0 | 0.5 | 0.1 | 0.8 | 0.3 |
| input.lastInputMs | HidReader | 3000 | 0 | 0.3 | 0.1 | 0.5 | 0.1 |
| input.motionSender | HidReader | 624 | 0 | 0.1 | 0.1 | 0.5 | 0.1 |
| input.motionTap | HidReader | 624 | 0 | 0.2 | 0.1 | 0.2 | 0.1 |
| input.processor | HidReader | 6000 | 0 | 18.6 | 2.0 | 69.8 | 2.0 |
| input.reportSender | HidReader | 3000 | 0 | 0.3 | 0.1 | 0.9 | 0.5 |
| input.reportTap | HidReader | 3000 | 0 | 0.2 | 0.1 | 0.6 | 0.3 |
| input.tally | HidReader | 3624 | 0 | 0.2 | 0.1 | 1.1 | 0.5 |
| routing.sent | HidReader | 3000 | 0 | 0.1 | 0.1 | 0.2 | 0.1 |
| routing.table | HidReader | 3624 | 0 | 0.2 | 0.1 | 15.8 | 2.0 |
| satellite.params | HidReader | 3624 | 0 | 0.2 | 0.1 | 16.8 | 1.0 |
| satellite.send | HidReader | 7248 | 0 | 2.0 | 0.3 | 119.9 | 65.5 |
| forwarding.gate | Receive | 60 | 0 | 0.1 | 0.1 | 0.1 | 0.1 |
| routing.table | Receive | 600 | 3 | 76.9 | 0.1 | 7.0 | 4.1 |
| satellite.ackRunning | Receive | 690 | 0 | 0.4 | 0.5 | 1.1 | 2.0 |
| satellite.connectionAlive | Receive | 2 | 0 | 0.0 | 0.1 | 0.1 | 0.1 |
| satellite.heartbeatAck | Receive | 2 | 0 | 0.0 | 0.1 | 0.1 | 0.1 |
| satellite.lastRecvCounter | Receive | 1324 | 0 | 0.2 | 0.3 | 15.9 | 0.3 |
| satellite.latency | Receive | 2 | 0 | 0.2 | 0.3 | 1.2 | 2.0 |
| satellite.missedAcks | Receive | 2 | 0 | 0.0 | 0.0 | 0.1 | 0.1 |
| satellite.onLightbar | Receive | 60 | 0 | 0.1 | 0.1 | 0.3 | 0.5 |
| satellite.onRumble | Receive | 600 | 0 | 0.2 | 0.1 | 0.6 | 0.5 |
| satellite.params | Receive | 662 | 3 | 26.5 | 0.5 | 18.1 | 8.2 |
| satellite.send | Receive | 690 | 187 | 575.6 | 262.1 | 9.3 | 1.0 |

The send lock is where the threads meet. The receive loop takes it every time it reads the socket and
found it held 187 times in 690 (27%), waiting up to 576 us; the capture queue found it held 97 times in 300
(32%). On the input queue it was held for up to 4.7 ms, a `sendto` descheduled under it.
