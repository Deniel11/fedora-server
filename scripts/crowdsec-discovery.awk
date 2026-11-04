function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
{
    line = trim($0)
    if (line !~ /^access_log[ \t]+/) next
    sub(/^access_log[ \t]+/, "", line)
    target = ""
    quote = substr(line, 1, 1)
    if (quote == "\"" || quote == "\047") {
        rest = substr(line, 2)
        escaped = 0
        for (i = 1; i <= length(rest); i++) {
            char = substr(rest, i, 1)
            if (char == quote && !escaped) { target = substr(rest, 1, i - 1); break }
            if (char == "\\" && !escaped) escaped = 1; else escaped = 0
        }
        if (target == "") next
    } else {
        sub(/[; \t].*$/, "", line)
        target = line
    }
    if (target == "off" || target ~ /^syslog:/ || target !~ /^\//) next
    gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\}/, "*", target)
    gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "*", target)
    gsub(/\$[0-9]+/, "*", target)
    if (target ~ /[\r\n]/) next
    print target
}
