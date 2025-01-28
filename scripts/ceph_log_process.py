import json
import sys
import argparse
from pprint import pprint


def parse_opts(argv):
    parser = argparse.ArgumentParser(description='Parameters')
    parser.add_argument('-l', '--log', metavar='LOG',
                        help=("Json Log file to parse"),
                        default=None)
    opts = parser.parse_args(argv[1:])
    return opts


if __name__ == "__main__":

    OPTS = parse_opts(sys.argv)
    if OPTS.log is None:
        print("No valid log input file passed")
        sys.exit(1)

    # Try to read the input log file
    try:
        with open(OPTS.log, "r") as f:
            d = json.load(f)
            f.close()
        pprint(d[1])
    except OSError as oe:
        print(oe)
        sys.exit(1)

##################################################
#
# USAGE:
#
# python prettyprint.py --log /tmp/ceph_health.log
#
##################################################
