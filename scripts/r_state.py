#!/usr/bin/env python3
"""Read-only: what are Apache's busy workers doing right now?

Run on the server:  ssh ubuntu@unglue.it 'python3 - unglue.it' < scripts/r_state.py
Reads https://<site>/server-status (the page the status sampler already uses)
and `ss`. Prints counts only: worker states, how long workers have been in their
current request, and client address ranges (/16) -- no full IPs, no URLs.
"""
import collections, re, subprocess, sys

site = sys.argv[1] if len(sys.argv) > 1 else "unglue.it"
html = subprocess.run(["curl", "-sk", "--fail", "--max-time", "8", "--noproxy", "*", "--resolve", f"{site}:443:127.0.0.1",
                       f"https://{site}/server-status"], capture_output=True, text=True).stdout
if not html:
    raise SystemExit("server-status fetch failed (same method as status_sampler.sh)")

# Worker table rows: Srv | PID | Acc | M | CPU | SS | Req | Dur | Conn | Child | Slot | Client | Protocol | VHost | Request
rows = re.findall(r"<tr><td><b>[^<]*</b></td>(.*?)</tr>", html, re.S)
cells = [re.findall(r"<td[^>]*>(.*?)</td>", r, re.S) for r in rows]
mode_counts = collections.Counter()
ss_by_mode = collections.defaultdict(list)
prefix_by_mode = collections.defaultdict(collections.Counter)
proto_by_mode = collections.defaultdict(collections.Counter)
for c in cells:
    if len(c) < 12:
        continue
    mode = re.sub(r"<.*?>", "", c[2]).strip()  # M column
    try:
        ss = int(re.sub(r"<.*?>", "", c[4]).strip())  # SS = seconds since start of most recent request
    except ValueError:
        continue
    client = re.sub(r"<.*?>", "", c[10]).strip()
    proto = re.sub(r"<.*?>", "", c[11]).strip()
    mode_counts[mode] += 1
    ss_by_mode[mode].append(ss)
    m = re.match(r"(?:::ffff:)?(\d+\.\d+)\.", client)
    prefix_by_mode[mode][(m.group(1) + ".x.x") if m else (client or "?")] += 1
    proto_by_mode[mode][proto or "?"] += 1

print("server-status worker rows parsed:", sum(mode_counts.values()), "(0 means the table layout differs; paste the first lines of /server-status)")
print("workers by mode:", dict(mode_counts))
for mode in ("R", "W"):
    v = sorted(ss_by_mode.get(mode, []))
    if v:
        q = lambda p: v[min(len(v) - 1, int(p * len(v)))]
        print(f"mode {mode}: n={len(v)} seconds-in-state p10={q(.1)} p50={q(.5)} p90={q(.9)} max={v[-1]}  >40s={sum(x > 40 for x in v)}  >120s={sum(x > 120 for x in v)}")
        print(f"  protocol: {dict(proto_by_mode[mode])}")
        print(f"  client ranges: {prefix_by_mode[mode].most_common(10)}")

out = subprocess.run(["ss", "-Htn", "state", "established", "( sport = :443 or sport = :80 )"], capture_output=True, text=True).stdout.splitlines()
prefixes = collections.Counter()
for line in out:
    parts = line.split()
    if len(parts) >= 4:
        m = re.search(r"(\d+\.\d+)\.\d+\.\d+", parts[3])
        prefixes[(m.group(1) + ".x.x") if m else "other"] += 1
print("established connections on 80/443:", len(out))
print("  by /16:", prefixes.most_common(12))
