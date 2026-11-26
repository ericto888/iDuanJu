"""Number helpers (original implementation for i短剧, GPL-3.0)."""

import math
import random as _random

_system = _random.SystemRandom()
sieve_base = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97)


def ceil_div(n, d):
    if d == 0:
        raise ZeroDivisionError()
    if n < 0 or d < 0:
        raise ValueError("Non positive values")
    return -(-n // d)


def size(N):
    if N < 0:
        raise ValueError("Size in bits only available for non-negative numbers")
    return N.bit_length()


def GCD(x, y):
    return math.gcd(x, y)


def inverse(u, v):
    if v == 0:
        raise ZeroDivisionError("Modulus cannot be zero")
    if v < 0:
        raise ValueError("Modulus cannot be negative")
    return pow(u, -1, v)


def getRandomInteger(N, randfunc=None):
    return _system.getrandbits(N) if N else 0


def getRandomNBitInteger(N, randfunc=None):
    return getRandomInteger(N - 1) | (1 << (N - 1))


def getRandomRange(a, b, randfunc=None):
    return _system.randrange(a, b)


def isPrime(N, false_positive_prob=1e-6, randfunc=None):
    """Miller-Rabin."""
    N = int(N)
    if N < 2:
        return False
    for p in sieve_base:
        if N % p == 0:
            return N == p
    odd, twos = N - 1, 0
    while odd % 2 == 0:
        odd //= 2
        twos += 1
    for _ in range(max(8, int(-math.log(false_positive_prob) / math.log(4)) + 1)):
        x = pow(_system.randrange(2, N - 1), odd, N)
        if x in (1, N - 1):
            continue
        for _ in range(twos - 1):
            x = x * x % N
            if x == N - 1:
                break
        else:
            return False
    return True


def getPrime(N, randfunc=None):
    if N < 2:
        raise ValueError("N must be larger than 1")
    while True:
        candidate = getRandomNBitInteger(N) | 1
        if N == 2:
            return _system.choice((2, 3))
        if isPrime(candidate):
            return candidate


def long_to_bytes(n, blocksize=0):
    if n < 0 or blocksize < 0:
        raise ValueError("Values must be non-negative")
    out = n.to_bytes((n.bit_length() + 7) // 8 or 1, "big")
    if blocksize:
        out = out.rjust(ceil_div(len(out), blocksize) * blocksize, b"\x00")
    return out


def bytes_to_long(s):
    return int.from_bytes(s, "big")


def long2str(n, blocksize=0):
    raise NotImplementedError("long2str() 已废弃，请使用 long_to_bytes()")


def str2long(s):
    raise NotImplementedError("str2long() 已废弃，请使用 bytes_to_long()")
