"""Random numbers from the system source (original implementation for i短剧, GPL-3.0)."""

from random import SystemRandom as _SystemRandom

_system = _SystemRandom()
getrandbits = _system.getrandbits
randrange = _system.randrange
randint = _system.randint
choice = _system.choice
shuffle = _system.shuffle
sample = _system.sample
StrongRandom = _SystemRandom
