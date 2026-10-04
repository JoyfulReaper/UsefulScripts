#!/usr/bin/env python3
"""Decode DN42 standard BGP communities from `birdc show route ... all` output.

Usage:
    sudo birdc 'show route for 172.22.105.8/29 all' | ./dn42-route-report.py

The script is read-only. It consumes BIRD route output from standard input; it
does not connect to BIRD, query BIRD itself, or modify BIRD configuration or
state. It separates candidate paths, marks the selected path, and renders
AS64511/DN42 standard communities as human-readable metadata.
"""

import re
import sys

LATENCY = {
    1: "0-2.7 ms",
    2: "2.7-7.3 ms",
    3: "7.3-20 ms",
    4: "20-55 ms",
    5: "55-148 ms",
    6: "148-403 ms",
    7: "403-1096 ms",
    8: "1096-2981 ms",
    9: ">2981 ms",
}

BANDWIDTH = {
    21: ">= 0.1 Mbps",
    22: ">= 1 Mbps",
    23: ">= 10 Mbps",
    24: ">= 100 Mbps",
    25: ">= 1 Gbps",
    26: ">= 10 Gbps",
    27: ">= 100 Gbps",
    28: ">= 1 Tbps",
    29: ">= 10 Tbps",
}

CRYPTO = {
    31: "unencrypted",
    32: "unsafe VPN",
    33: "safe, no PFS",
    34: "safe + PFS",
    35: "PFS + PQ resistance",
    36: "post-quantum forward secrecy",
}

TOPOLOGY = {
    81: "physical",
    82: "IX",
    83: "tunnel",
    84: "meshed virtual IX",
    85: "centralized virtual IX",
    89: "unknown/other",
}

LOSS = {
    91: "almost 0%",
    92: "<= 1%",
    93: "<= 5%",
    94: "> 5%",
}

REGION = {
    42: "North America-East",
    43: "North America-Central",
    44: "North America-West",
}

COUNTRY = {
    1840: "United States",
}


def decode(values):
    result = []

    for value in values:
        if value in LATENCY:
            result.append(("latency", LATENCY[value], value))
        elif value in BANDWIDTH:
            result.append(("bandwidth", BANDWIDTH[value], value))
        elif value in CRYPTO:
            result.append(("crypto", CRYPTO[value], value))
        elif value in TOPOLOGY:
            result.append(("topology", TOPOLOGY[value], value))
        elif value in LOSS:
            result.append(("loss", LOSS[value], value))
        elif value in REGION:
            result.append(("region", REGION[value], value))
        elif value in COUNTRY:
            result.append(("country", COUNTRY[value], value))
        else:
            result.append(("other", f"64511:{value}", value))

    return result


def main():
    lines = sys.stdin.read().splitlines()
    paths = []
    current = None

    route_re = re.compile(
        r"^\s*(?:(\S+)\s+)?(?:unicast|unreachable|blackhole|prohibit)\s+"
        r"\[([^\s\]]+)"
    )

    for line in lines:
        match = route_re.match(line)

        if match:
            current = {
                "prefix": match.group(1),
                "protocol": match.group(2),
                "selected": bool(re.search(r"\]\s+\*", line)),
                "as_path": None,
                "next_hop": None,
                "local_pref": None,
                "med": None,
                "communities": [],
            }
            paths.append(current)
            continue

        if current is None:
            continue

        stripped = line.strip()

        if stripped.startswith("BGP.as_path:"):
            current["as_path"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("BGP.next_hop:"):
            current["next_hop"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("BGP.local_pref:"):
            current["local_pref"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("BGP.med:"):
            current["med"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("BGP.community:"):
            current["communities"] = [
                int(value)
                for asn, value in re.findall(r"\((\d+),\s*(\d+)\)", stripped)
                if int(asn) == 64511
            ]

    if not paths:
        print("No route paths found.")
        return 1

    for index, path in enumerate(paths, 1):
        status = "SELECTED" if path["selected"] else "alternate"
        print(f"Path {index}: {path['protocol']} [{status}]")

        if path["as_path"] is not None:
            print(f"  AS path:    {path['as_path'] or '(iBGP/local)'}")
        if path["next_hop"] is not None:
            print(f"  next hop:   {path['next_hop']}")
        if path["local_pref"] is not None:
            print(f"  local-pref: {path['local_pref']}")
        if path["med"] is not None:
            print(f"  MED:        {path['med']}")

        decoded = decode(path["communities"])
        if not decoded:
            print("  DN42 metadata: none")
        else:
            for kind, label, value in decoded:
                print(f"  {kind + ':':<11} {label} (64511:{value})")

        if index != len(paths):
            print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
