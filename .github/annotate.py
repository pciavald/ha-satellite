import sys

title = sys.argv[1]
text = sys.stdin.read().replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::error title={title}::{text}")
