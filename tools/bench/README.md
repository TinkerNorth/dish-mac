# Dish Mac frame-path bench

`DishBench` (`Sources/DishBench`) times the Mac client's frame path with the production objects in their
thread roles, and counts every lock each role takes. `.github/workflows/measurements.yml` runs it on every
release and attaches the record to the release. This file is the method and the record.

## What is timed

A pad's report travels, on one thread, from its controller's own handler queue
(`com.tinkernorth.dish.input.<slot id>`) through the pad's gate, its `PadFeed` (latch, dead zones, record,
the route it holds) and `SatelliteClient.sendEncrypted` to `sendto`; a Direct pad's report makes the same
trip from IOKit's input-report callback on the reader's thread. (Before the optimisation it went through the
processor's lock, the routing table and the connection's client reference instead of the feed.) The bench drives exactly those objects:
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

A pad bound to a Moonlight host (S7) leaves its feed for a `MoonlightPadSink`: the host's `MoonlightPadLink`
turns the report into a CONTROLLER_MULTI frame, `MoonlightControlSession` seals it under the session's next
control sequence and frames it as an ENet reliable command, and `UdpControlTransport` hands the datagram to
its `NWConnection`. `MoonlightPathRig` wires that path as the manager and `AppModel` do: a
`MoonlightConnection` with its link, a control session over the real UDP transport with the connection's
50 ms clock ticking it, and the host's events through `MoonlightFeedbackRouter` to counters. The host is
`LoopbackMoonlightHost`, one socket and one thread: it answers the ENet handshake, acknowledges every
command, opens every sealed packet with the session's rikey and stamps it after the decrypt, and sends its
rumble and RGB-LED events back as sealed reliable commands. The frame's sequence rides the right stick's X,
as on the input queue.

## Scenarios

| scenario | runs |
| --- | --- |
| S1 | pad A on the input queue at `--rate` (1000 Hz) |
| S2 | S1 and pad B at 250 Hz on a queue of its own, as each controller has one (one queue shared by both before the optimisation, as GameController then shared one) |
| S3 | S2 and the main actor refreshing the routing table every 100 ms, as `AppModel.refreshRouting` does, and reading the tally every second |
| S4 | S3 and the satellite sending 100 rumble and 10 light-bar commands a second into the real receive path |
| S5 | S4 and the 2 s heartbeat and microphone packets from the capture queue at `--mic-hz` (50; also run at 1000) |
| S6 | a Direct Switch Pro pad at 1000 Hz on a HidReader-role thread, input and motion in every report |
| S7 | pad A bound to a Moonlight host on the loopback at `--rate`, the host sending 100 rumble and 10 RGB-LED events a second into the control session's receive path |

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
reports fed; 1.00 for a pad on the input queue, about 1.2 for the Direct pad; in S7 every input packet
naming the pad) and `drops` (fed but never arrived).

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
locks taken inside another, plus a check that the nesting has no cycle. Every list is empty: a lock that
appears on a hot role fails the test. A second run puts a pad on a loopback Moonlight host, whose events
arrive on the control socket's queue (MoonlightUdp), and holds the Input and MoonlightUdp roles, the
blocking calls and the nesting to lists of their own: the session's lock on both roles, by design, held
for the ENet bookkeeping alone, and as debt the pad link's and the transport's locks on both and the
feedback path's on MoonlightUdp (its handler, the pad link's slot lookup, the rumble mix, the routing
table and the light-bar switch).

## Release measurements

`measurements.yml` runs on pull requests that touch `Sources/` or the lock laws, by hand, and from
`release.yml` as the `measurements` job after the hardened bundle; `publish` needs it and ships its two
files beside the app. One `macos-26` job builds the bench plain and with lock statistics, runs the lock
laws, fetches the latest release's `measurements-*.json`, runs each build over every scenario and once
more with `--only S5 --mic-hz 1000`, and has `DishBench report` write `measurements-<version>.md` (the job
summary) and `measurements-<version>.json`; both are the `measurements` artifact and every rep is
`measurements-raw`.

- **Lock gate (fails the job).** The Input, HidReader and Receive roles take no lock in any lock-stats
  run (`--enforce-lock-gate`) of S1 to S6. A lock-stats run that recorded no lock at all cannot pass either.
  S7 is measured and not gated: the Moonlight send takes its session's lock for the ENet bookkeeping, and
  the Moonlight lock laws pin what that path takes instead.
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

## After: the optimised frame path

The branch's head after the optimisation commits, `3b6a897`, measured by `measurements.yml` on the pull request:
run [41427026294](https://github.com/TinkerNorth/dish-mac/actions/runs/41427026294), attempt 1 and its re-run,
attempt 2, both on the pull request's merge commit `819755a`. The runner is the baseline's (`macos-26`, Apple M1
(Virtual), VirtualMac2,1, 3 cores, 7.0 GB, macOS 26.6.2). Time-constrained waits woke 1040 us late at the 90th
percentile in the first run and 836 us in the second, so their pacers spun 1000 and 936 us; the baseline's plain
run had 268 us. The commands are the baseline's, as the workflow runs them. Since then the workflow passes
`--enforce-lock-gate`.

### Locks, lock-stats build

The Input, HidReader and Receive roles took no lock in either run: no acquisition per report on the input queue
(12 before), none per Direct report (about 15.7) and none per rumble datagram (7), and no lock is held across
`sendto` (`satellite.send` was, for up to 4.7 ms). The senders meet only at the session's send gate. What is left
is the cold side, below from the second run, every scenario's reported rep merged: the microphone's connection
lookup on the capture queue, the heartbeat's latency window, and the main actor's routing refreshes (S3 to S5
refresh every 100 ms), feed registry and handler sets.

| lock | role | acquisitions | contended | max wait us | p99 wait us | max hold us | p99 hold us |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| connection.client | AudioCapture | 150 | 0 | 0.2 | 0.3 | 0.7 | 1.0 |
| satellite.latency | Heartbeat | 2 | 0 | 1.1 | 2.0 | 0.4 | 0.5 |
| connection.client | Main | 182 | 0 | 0.2 | 0.3 | 0.9 | 1.0 |
| input.feeds | Main | 63 | 0 | 5.9 | 8.2 | 3.0 | 4.1 |
| routing.table | Main | 54 | 0 | 0.2 | 0.3 | 0.9 | 1.0 |
| satellite.handlers | Main | 54 | 0 | 0.0 | 0.1 | 6.2 | 8.2 |
| satellite.latency | Main | 20 | 0 | 1.5 | 2.0 | 4.5 | 8.2 |

### Latency, plain build

The reported rep of each scenario in both runs, the run's number first. Latencies in microseconds; `longest gap`
in milliseconds. S2's pad B now has a queue of its own, as each controller has.

| run | scenario | pad | source | rate Hz | frames | p50 us | p99 us | p99.9 us | max us | over 1 ms | longest gap ms | datagrams/report | drops |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1: plain | S1 | A | Input | 1000 | 3000 | 72.5 | 1549.5 | 2425.9 | 3558.8 | 204 | 1775.381 | 1.00 | 0 |
| 2: plain | S1 | A | Input | 1000 | 3000 | 40.2 | 117.5 | 260.9 | 396.0 | 0 | 1.221 | 1.00 | 0 |
| 1: plain | S2 | A | Input | 1000 | 3000 | 70.3 | 189.9 | 503.5 | 2357.6 | 1 | 4.065 | 1.00 | 0 |
| 2: plain | S2 | A | Input | 1000 | 3000 | 44.0 | 995.0 | 1842.0 | 5085.5 | 23 | 8.223 | 1.00 | 0 |
| 1: plain | S2 | B | Input | 250 | 750 | 69.9 | 208.6 | 545.3 | 545.3 | 0 | 4.305 | 1.00 | 0 |
| 2: plain | S2 | B | Input | 250 | 750 | 47.1 | 495.4 | 2531.8 | 2531.8 | 3 | 8.812 | 1.00 | 0 |
| 1: plain | S3 | A | Input | 1000 | 3000 | 126.8 | 1155.0 | 2961.6 | 3733.8 | 35 | 11.466 | 1.00 | 0 |
| 2: plain | S3 | A | Input | 1000 | 3000 | 40.0 | 227.5 | 1031.6 | 1045.2 | 11 | 2.007 | 1.00 | 0 |
| 1: plain | S3 | B | Input | 250 | 750 | 122.6 | 1287.9 | 6144.4 | 6144.4 | 12 | 12.902 | 1.00 | 0 |
| 2: plain | S3 | B | Input | 250 | 750 | 44.2 | 991.0 | 998.8 | 998.8 | 0 | 4.959 | 1.00 | 0 |
| 1: plain | S4 | A | Input | 1000 | 3000 | 84.8 | 5678.7 | 11634.2 | 28441.7 | 184 | 64.493 | 1.00 | 0 |
| 2: plain | S4 | A | Input | 1000 | 3000 | 44.1 | 1002.7 | 1327.8 | 3738.5 | 40 | 4.307 | 1.00 | 0 |
| 1: plain | S4 | B | Input | 250 | 750 | 124.1 | 10879.8 | 23712.9 | 23712.9 | 70 | 60.576 | 1.00 | 0 |
| 2: plain | S4 | B | Input | 250 | 750 | 55.8 | 3045.9 | 5557.2 | 5557.2 | 30 | 9.502 | 1.00 | 0 |
| 1: plain | S5 | A | Input | 1000 | 3000 | 128.8 | 1369.6 | 5174.3 | 7780.3 | 51 | 12.316 | 1.05 | 0 |
| 2: plain | S5 | A | Input | 1000 | 3000 | 60.4 | 15868.2 | 37040.8 | 49999.8 | 528 | 50.944 | 1.05 | 0 |
| 1: plain | S5 | B | Input | 250 | 750 | 126.6 | 2232.5 | 7825.8 | 7825.8 | 20 | 14.701 | 1.00 | 0 |
| 2: plain | S5 | B | Input | 250 | 750 | 80.8 | 20105.2 | 46049.7 | 46049.7 | 128 | 64.034 | 1.00 | 0 |
| 1: plain | S6 | A | HidReader | 1000 | 3000 | 165.3 | 4735.2 | 7794.5 | 9789.7 | 289 | 12.364 | 1.21 | 0 |
| 2: plain | S6 | A | HidReader | 1000 | 3000 | 49.8 | 2617.6 | 4937.4 | 16781.3 | 168 | 16.787 | 1.21 | 0 |
| 1: plain-mic1000 | S5 | A | Input | 1000 | 3000 | 65.2 | 1810.0 | 4375.0 | 5784.0 | 134 | 8.544 | 2.00 | 0 |
| 2: plain-mic1000 | S5 | A | Input | 1000 | 3000 | 51.3 | 978.9 | 1508.2 | 26799.6 | 26 | 27.500 | 2.00 | 0 |
| 1: plain-mic1000 | S5 | B | Input | 250 | 750 | 89.0 | 2103.0 | 5592.8 | 5592.8 | 44 | 9.886 | 1.00 | 0 |
| 2: plain-mic1000 | S5 | B | Input | 250 | 750 | 74.9 | 1267.0 | 1399.7 | 1399.7 | 8 | 29.772 | 1.00 | 0 |

In the second run pad A's median is 40 to 60 us in the reported rep of every scenario, against 96 to 123 us
before, and the Direct pad's 50 us against 108 us; S1's p99 is 118 us against 634 us, and every rep of S1 to S4
has a median under 47 us. The first run, on a busier host, has reported medians of 65 to 129 us for pad A and
165 us for the Direct pad: the baseline's range, and above it for the Direct pad. The tails belong to the runner
more than to the path: both runs have reps with gaps between arrivals of 49 ms to 1.8 s, and so do the runs this
pull request measured after its first commits, while the input threads still took most of their locks (a 124 ms
gap in S1 after the first three commits, and 474 ms with a 44 ms p99 in S2 after the first four), where the
baseline's run had none over 27 ms. Judge a change on the medians and the lock counts, over more than one run.

Per report the send path allocates nothing of its own: the payload, the inner frame, the nonce, the AAD and the
datagram are built in a stack buffer, and CryptoKit's sealed box is the one heap object (up to eight of Dish's
own beside it before; `Data` keeps the smallest inline). The receive loop reads into the client's own buffer;
per datagram it allocates only CryptoKit's copy of the box and the plaintext it returns, and an audio frame's
Opus bytes (a 1500-byte array and up to ten more copies of Dish's own before).

## The Moonlight path (S7)

S7 measures a pad bound to a Moonlight host, before and after the control session's lock was narrowed to
its ENet bookkeeping. The release gate does not judge it; the Moonlight lock laws pin what it takes.

### Before: the session's lock over the crypto

The branch with S7 and its laws, `54fdbe9`, measured by `measurements.yml` on the pull request: run
[41463274956](https://github.com/TinkerNorth/dish-mac/actions/runs/41463274956) on the merge commit `8a08c02`.
The runner is the baseline's (`macos-26`, Apple M1 (Virtual), VirtualMac2,1, 3 cores, 7.0 GB, macOS 26.6.2).
Time-constrained waits woke 973 us late at the 90th percentile, so the pacers spun 1000 us. The commands are
the baseline's.

| run | scenario | pad | source | rate Hz | frames | p50 us | p99 us | p99.9 us | max us | over 1 ms | longest gap ms | datagrams/report | drops |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| plain | S7 | A | Input | 1000 | 3000 | 111.5 | 476.6 | 1223.6 | 3046.3 | 7 | 4.361 | 1.00 | 0 |

Pad A's median was 111.5, 69.0 and 86.3 us in the three plain reps. Every rumble (300 a rep) and RGB-LED
event (30) reached the actuators, and no frame was dropped. The lock-stats build's reported rep:

| lock | role | acquisitions | contended | max wait us | p99 wait us | max hold us | p99 hold us |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| moonlight.padLink | Input | 3000 | 0 | 31.9 | 0.3 | 282.3 | 4.1 |
| moonlight.session | Input | 3000 | 6 | 282.2 | 0.1 | 904.8 | 131.1 |
| moonlight.transport | Input | 3000 | 2 | 371.0 | 2.0 | 93.0 | 0.5 |
| forwarding.gate | MoonlightUdp | 30 | 0 | 0.1 | 0.1 | 0.1 | 0.1 |
| moonlight.feedbackHandler | MoonlightUdp | 330 | 0 | 0.2 | 0.3 | 7.2 | 1.0 |
| moonlight.padLink | MoonlightUdp | 330 | 0 | 0.2 | 0.1 | 0.9 | 0.5 |
| moonlight.rumbleMixes | MoonlightUdp | 300 | 0 | 0.2 | 0.3 | 29.4 | 4.1 |
| moonlight.session | MoonlightUdp | 3335 | 10 | 392.5 | 0.3 | 324.5 | 32.8 |
| moonlight.transport | MoonlightUdp | 7001 | 1 | 103.0 | 1.0 | 1445.4 | 0.5 |
| routing.table | MoonlightUdp | 300 | 0 | 0.2 | 0.1 | 12.5 | 2.0 |
| moonlight.session | Heartbeat | 37 | 1 | 30.7 | 32.8 | 20.8 | 32.8 |
| moonlight.transport | Heartbeat | 5 | 0 | 0.4 | 0.5 | 0.1 | 0.1 |

Each frame takes three locks on the input queue: the pad link's, the session's and the transport's. The
session's is where the threads meet. The input queue held it to seal and frame each frame, for up to 905 us;
the control socket's queue held it to take each datagram in and open what the host sent, for up to 325 us;
each found it held, 6 times in 3000 on the input queue (waiting up to 282 us) and 10 in 3335 on the socket's
queue (up to 392 us). The socket's queue also takes the transport's lock twice for every datagram the
connection finishes sending, and the feedback path takes four locks for each rumble (its handler, the pad
link's slot lookup, the rumble mix and the routing table) and three for each RGB-LED event.

### After: the lock holds the ENet bookkeeping alone

The head after the lock change, `12c95d2`, measured by `measurements.yml` on the pull request: run
[41465878700](https://github.com/TinkerNorth/dish-mac/actions/runs/41465878700), attempt 1 and its re-run,
attempt 2, both on the merge commit `b036bdf`. The runner is the baseline's. Time-constrained waits woke
1060 and 495 us late at the 90th percentile, so the pacers spun 1000 and 595 us. The commands are the
baseline's.

| run | scenario | pad | source | rate Hz | frames | p50 us | p99 us | p99.9 us | max us | over 1 ms | longest gap ms | datagrams/report | drops |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1: plain | S7 | A | Input | 1000 | 3000 | 125.3 | 789.7 | 3428.9 | 4880.5 | 24 | 6.029 | 1.00 | 0 |
| 2: plain | S7 | A | Input | 1000 | 3000 | 103.0 | 323.9 | 1894.8 | 2926.1 | 12 | 5.095 | 1.00 | 0 |

The latency does not show the change. Pad A's median was 125.3, 106.4 and 156.3 us in the first run's reps
and 94.1, 111.0 and 103.0 us in the second's, against 111.5, 69.0 and 86.3 us before, and the same runs
moved the untouched satellite scenarios as far (S6's Direct pad: 52 us before, 105 and 98 us after). To
take the runner out of it, a scratch workflow built both heads on one runner and ran S7 on each five times,
alternating (run [41467803003](https://github.com/TinkerNorth/dish-mac/actions/runs/41467803003)): over the
fifteen reps of each, pad A's median was 116.4 us before and 120.0 us after, and the median p99 613 and 655
us. Every rumble and RGB-LED event reached the actuators and no frame was dropped in any of them.

The second run's lock-stats build, the reported rep:

| lock | role | acquisitions | contended | max wait us | p99 wait us | max hold us | p99 hold us |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| moonlight.padLink | Input | 3000 | 0 | 12.4 | 0.5 | 158.1 | 2.0 |
| moonlight.session | Input | 3000 | 7 | 129.1 | 0.1 | 87.7 | 8.2 |
| moonlight.transport | Input | 3000 | 0 | 24.8 | 2.0 | 7.1 | 0.5 |
| forwarding.gate | MoonlightUdp | 30 | 0 | 0.1 | 0.1 | 0.1 | 0.1 |
| moonlight.feedbackHandler | MoonlightUdp | 330 | 0 | 0.2 | 0.1 | 5.7 | 1.0 |
| moonlight.padLink | MoonlightUdp | 330 | 0 | 0.2 | 0.1 | 0.7 | 0.5 |
| moonlight.rumbleMixes | MoonlightUdp | 300 | 0 | 0.3 | 0.3 | 14.8 | 16.4 |
| moonlight.session | MoonlightUdp | 3336 | 5 | 30.8 | 0.3 | 39.5 | 16.4 |
| moonlight.transport | MoonlightUdp | 7002 | 0 | 14.0 | 1.0 | 15.2 | 0.5 |
| routing.table | MoonlightUdp | 300 | 0 | 0.2 | 0.1 | 18.0 | 2.0 |
| moonlight.session | Heartbeat | 38 | 0 | 0.5 | 0.5 | 5.5 | 8.2 |
| moonlight.transport | Heartbeat | 6 | 0 | 0.9 | 1.0 | 0.1 | 0.1 |

The same locks are taken as often; what changed is what is held. In the second run the session's lock was
held on the input queue for up to 87.7 us, 8.2 us at the 99th percentile (905 and 131 us in the baseline's
run), and on the socket's queue for up to 39.5 us, 16.4 us at the 99th percentile (325 and 33 us). Those
runs had different hosts under them, so the scratch workflow ran the same comparison on one runner, both
heads' lock-stats builds alternating five times each, fifteen reps a side (run
[41469232780](https://github.com/TinkerNorth/dish-mac/actions/runs/41469232780)). The session's lock was held
for 131 us at the 99th percentile on the input queue before the change and 16 us after, 66 and 33 us on the
socket's queue and 131 and 16 us on the tick (each the top of its power-of-two bucket, the median over the
reps). The socket's queue found it held 233 times in 52970 acquisitions before and 51 times in 50082 after,
and the tick 58 times in 543 and 5 in 652.

On the input queue the lock was found held about as rarely as before (82 and then 65 times in 45000), so at
this load almost no report waited on it, and the latency holds where it was. What the change removes is the
wait behind somebody else's crypto: a report no longer waits for the host's packet to be opened, nor for
another sender's seal, and `MoonlightControlSessionLockTests` holds the session to that. The pad link's and
the transport's locks on the input queue and the feedback path's on the socket's queue are the Moonlight
path's remaining debt.
