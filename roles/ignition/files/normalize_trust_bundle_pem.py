#!/usr/bin/env python3
"""Read PEM trust bundle from stdin; collapse Terraform/JSON literal \\n and \\r\\n to real newlines.

openshift-install rejects additionalTrustBundle when PEM blocks are joined by the two-character
sequence backslash + n instead of actual newlines (common when mirror CA strings are embedded in JSON).
"""
import sys


def main() -> None:
    s = sys.stdin.read()
    for _ in range(256):
        prev = s
        s = s.replace("\r\n", "\n")
        s = s.replace("\\r\\n", "\n")
        s = s.replace("\\n\\n", "\n\n")
        s = s.replace("\\n", "\n")
        s = s.replace("\\r", "\r")
        if s == prev:
            break
    sys.stdout.write(s)


if __name__ == "__main__":
    main()
