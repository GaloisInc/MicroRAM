# Usage: python3 graph_segments.py out.cbor | dot -Tpdf -o segments.pdf
import cbor
import functools
import sys

path, = sys.argv[1:]
c = cbor.load(open(path, 'rb'))

segs = c[2]['segments']
trace = c[2]['trace']
labels = c[2]['labels']
labels_rev = {v: k for k,v in sorted(labels.items())}

def seg_public_pc(s):
    for constraint in s[0]:
        if constraint[0] == 'pc':
            return constraint[1]
    return None

seen = set(x[0] for x in trace)
prev_seg = {}
next_seg = {}
for x1, x2 in zip(trace, trace[1:]):
    i1, i2 = x1[0], x2[0]
    next_seg[i1] = i2
    prev_seg[i2] = i1

def maybe_green(flag, comma=False):
    if flag:
        return '%scolor = "green"' % (', ' if comma else '')
    else:
        return ''

@functools.lru_cache(None)
def pc_name(pc):
    def escape(s):
        return s.replace('\\', '\\\\').replace('"', '\\"')

    name = labels_rev.get(pc)
    if name is not None:
        return escape(name)

    prev_pc = None
    for k in labels_rev.keys():
        if k < pc and (prev_pc is None or k > prev_pc):
            prev_pc = k
    if prev_pc is None:
        return str(pc)

    prev_name = labels_rev[prev_pc]
    return '%s +%d' % (escape(prev_name), pc - prev_pc)

print('digraph {')
for i, seg in enumerate(segs):
    pc = seg_public_pc(seg)
    if pc is None:
        continue

    _, seg_len, succs, from_net, to_net = seg

    used_from_net = i in prev_seg and i not in segs[prev_seg[i]][2]
    used_to_net = i in next_seg and next_seg[i] not in succs

    print('seg%d [ label = "%d: %s", %s ];' % (i, i, pc_name(pc), maybe_green(i in seen)))
    if from_net:
        print('fromnet%d [ label = "*", %s ];' % (i, maybe_green(used_from_net)))
        print('fromnet%d -> seg%d [ %s ];' % (i, i, maybe_green(used_from_net)))
    if to_net:
        print('tonet%d [ label = "*", %s ];' % (i, maybe_green(used_to_net)))
        print('seg%d -> tonet%d [ %s ];' % (i, i, maybe_green(used_to_net)))
    for j in succs:
        print('seg%d -> seg%d [ %s ];' % (i, j, maybe_green(j == next_seg.get(i))))

    if to_net and used_to_net:
        print('netdest%d [ color = "blue", label = "to %d" ];' % (i, next_seg[i]))
        print('tonet%d -> netdest%d [ color = "blue" ];' % (i, i))

    if from_net and used_from_net:
        print('netsrc%d [ color = "blue", label = "from %d" ];' % (i, prev_seg[i]))
        print('netsrc%d -> fromnet%d [ color = "blue" ];' % (i, i))

print('}')

