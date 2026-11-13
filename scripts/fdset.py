"""Prints the hex of the FileDescriptorProto named NAME inside a FileDescriptorSet file.

Usage: python3 scripts/fdset.py SET.pb NAME   (stdlib only; field 1 of the set, field 1 of
each file is its name). Lets interop.sh compare what reflection served with protoc's bytes,
whatever the order of the files in each set.
"""
import sys


def varint(b, i):
    v = s = 0
    while True:
        x = b[i]
        i += 1
        v |= (x & 0x7F) << s
        s += 7
        if x < 0x80:
            return v, i


def fields(b):
    i = 0
    while i < len(b):
        key, i = varint(b, i)
        wire = key & 7
        if wire != 2:
            raise SystemExit("unexpected wire type %d" % wire)
        n, i = varint(b, i)
        yield key >> 3, b[i:i + n]
        i += n


def name_of(fd):
    i = 0
    while i < len(fd):
        key, i = varint(fd, i)
        wire = key & 7
        if wire == 0:
            _, i = varint(fd, i)
            continue
        n, i = varint(fd, i)
        if key >> 3 == 1:
            return fd[i:i + n].decode()
        i += n
    return ""


data = open(sys.argv[1], "rb").read()
for num, fd in fields(data):
    if num == 1 and name_of(fd) == sys.argv[2]:
        print(fd.hex())
        break
else:
    print("missing " + sys.argv[2])
