# Scrub a captured `container` payload before it is committed (record-fixtures.sh).
# Args: $home, $user, $host, $fqdn (may be empty), $keep: IPv4 /24 prefixes
# of the container networks ("172.30.240"), whose addresses tests pin.
def ipv4:
  gsub("\\b(?<p>[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})\\.(?<h>[0-9]{1,3})\\b";
       if (.p as $p | $keep | index([$p])) then "\(.p).\(.h)" else "203.0.113.\(.h)" end);
def scrub:
  (if $home != "" then split($home) | join("$HOME") else . end)
  | (if $user != "" then split("/Users/\($user)") | join("$HOME") else . end)
  | (if $fqdn != "" and ($fqdn | test("\\.")) then split($fqdn) | join("mac.local") else . end)
  | (if $host != "" and . == $host then "mac" else . end)
  | gsub("(?<n>\\b[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASS|AUTH|CREDENTIAL|COOKIE)[A-Za-z0-9_]*)=[^ \"]*"; "\(.n)=redacted"; "i")
  | gsub("\\b(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|tskey-[A-Za-z0-9-]{8,})"; "redacted")
  | gsub("(?i)bearer [A-Za-z0-9._~+/-]+=*"; "Bearer redacted")
  | gsub("\\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\\b"; "02:00:00:00:00:00")
  | gsub("\\b(f[cd][0-9a-fA-F]{2}|2[0-9a-fA-F]{3}|3fff)(:[0-9a-fA-F]{0,4}){1,7}"; "2001:db8::")
  | gsub("[A-Za-z0-9-]+\\.ts\\.net\\b"; "tailnet.ts.net")
  | ipv4;
# A running container's environment came from env files: keep only the names.
def runtime_env:
  if type == "object" and has("environment") and (.environment | type) == "array"
  then .environment |= map(if type == "string" and test("=") and (split("=")[0] | IN("PATH", "HOME", "TERM", "HOSTNAME") | not)
                           then (split("=")[0]) + "=redacted" else . end)
  else . end;
walk(runtime_env) | walk(if type == "string" then scrub elif type == "object" then with_entries(.key |= scrub) else . end)
