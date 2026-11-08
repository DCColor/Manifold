# cardlock-playwire.py <dir> <label>: the wire across each Play (docs/CARD_CLOCK_FINDINGS.md §10.10). `capture` was open before Play, so the
# marks hold the paused picture, the first new picture and what follows. A hold is the same picture for over 0.5 s. For each Play: the step into
# the first new picture, then every repeat or skip in the next 3 s or up to the next hold. The pulls ([CADENCE]) give how many pulls
# after the clock started still carried the paused picture, and each pull's picture, for comparison with the wire.
import re, sys
d, label = sys.argv[1], sys.argv[2]
nums = []
for l in open(f"{d}/{label}.marks"):
    f = l.split()
    if len(f) < 4: continue
    n = f[2] if f[2] != "?" else f[3]
    nums.append(None if n == "?" else int(n))
print("wire frames", len(nums), "unread", sum(n is None for n in nums))
L = open(f"{d}/{label}.log", errors="replace").read().splitlines()
fps = [float(x[1]) for l in L for x in [re.search(r"FILE source format \S+ @ ([\d.]+) fps", l)] if x][0]
fr = 1 / fps
hold = int(0.5 * fps)
i = 0; plays = []
while i < len(nums) - 1:
    j = i
    while j + 1 < len(nums) and nums[j + 1] == nums[i]: j += 1
    if j - i >= hold and j + 1 < len(nums):
        step = (nums[j + 1] - nums[i]) % 65536
        if step > 32768: step -= 65536
        ev = []; k = j + 1; end = min(len(nums) - 1, j + 1 + int(3 * fps))
        while k < end:
            s = (nums[k + 1] - nums[k]) % 65536
            if s == 0:
                r = k
                while r + 1 < len(nums) and nums[r + 1] == nums[k]: r += 1
                if r - k >= hold: break            # the next pause
                ev.append((k - j, "repeat", nums[k]))
            elif s != 1: ev.append((k - j, f"step{s if s < 32768 else s - 65536}", nums[k]))
            k += 1
        plays.append((j, nums[i], j - i + 1, step, ev, nums[max(0, j - 2):j + 7]))
    i = j + 1
for p in plays: print(f"wire frame {p[0]}: held {p[2]} frames of picture {p[1]}, step into motion {p[3]:+d}, after motion {p[4]}, sequence {p[5]}")
print("Plays", len(plays), "· step +1:", sum(p[3] == 1 for p in plays), "· other steps:", sorted({p[3] for p in plays if p[3] != 1}),
      "· Plays with a repeat or skip after motion:", sum(bool(p[4]) for p in plays))
cad = [(int(x[1]), float(x[2]), float(x[3]), float(x[4])) for l in L for x in [re.match(r"\[CADENCE\] #(\d+) host (\S+) pts (\S+) swapAgo \S+ clock (\S+)", l)] if x and x[3] != "nan" and x[4] != "nan"]
held = {}; i = 5
pull = []
while i < len(cad):
    if all(abs(cad[j][3] - cad[j - 1][3]) < 1e-6 for j in range(i - 4, i)) and cad[i][3] > cad[i - 1][3] + 1e-4:
        p0 = cad[i - 1][2]; j = i
        while j < len(cad) and abs(cad[j][2] - p0) < fr / 4: j += 1
        if j < len(cad):
            pull.append((round(p0 / fr), j - i, round((cad[j][2] - p0) / fr)))
            i = j
    i += 1
print("pulls: Plays", len(pull), "· held pulls after the clock started:", sorted({p[1] for p in pull}), "· step into motion:", sorted({p[2] for p in pull}))
print("pulls detail (picture, held, step):", pull)
