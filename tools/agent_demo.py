#!/usr/bin/env python3
"""agent_demo.py --ctl <folder> [--name Claude] [--scene 5] [--shot 5] [--pace 3.0]

Plays the part of an AI agent on the control protocol for the demo video (the agent segment of the tour): hello,
census, a jump to a scene, the Director on a shot, then director stop - one verb every --pace seconds so the Agent tab
and the arrange can be seen reacting. The agent switches (agent.enable, agent.allow_changes) must be on. Prints one
line per verb with the token that answered. Exit 0; 3 when Stagehand does not answer the ping.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stagehand_ctl import Ctl, CtlError  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ctl', required=True)
    ap.add_argument('--name', default='Claude')
    ap.add_argument('--scene', default='5')
    ap.add_argument('--shot', default='5')
    ap.add_argument('--pace', type=float, default=3.0)
    a = ap.parse_args()
    ctl = Ctl(a.ctl)
    try:
        ctl.ping(timeout=10)
    except CtlError as e:
        print('no answer: %s' % e)
        return 3
    steps = [('hello %s' % a.name, 'HELLO'), ('census', 'CENSUS'), ('nav jump scene %s' % a.scene, 'NAV'),
             ('director goto %s' % a.shot, 'DIRECTOR'), ('director stop', 'DIRECTOR')]
    for line, token in steps:
        t0 = time.time()
        try:
            reply = ctl.ask(line, token, timeout=15)
            print('%s -> %s (%.2f s)' % (line, reply.split()[1] if reply else token, time.time() - t0), flush=True)
        except CtlError as e:
            print('%s -> %s' % (line, e), flush=True)
        time.sleep(a.pace)
    return 0


if __name__ == '__main__':
    sys.exit(main())
