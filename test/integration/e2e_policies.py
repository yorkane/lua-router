#!/usr/bin/env python3
"""Policy matrix round: cache_aware / consistent_hashing / round_robin end to end,
plus virtual aliases, effort injection, the output-budget pass-through and the
worker_processes rule."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _lib

sys.exit(_lib.main() or 0)
