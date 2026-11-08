cfg_val() {
    k="$1"; d="$2"
    v=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_bool() {
    k="$1"; d="$2"
    v=$(sed -nE "s/.*\"$k\"[[:space:]]*:[[:space:]]*(true|false).*/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}
cfg_int() {
    k="$1"; d="$2"
    v=$(sed -nE "s/.*\"$k\"[[:space:]]*:[[:space:]]*(-?[0-9]+)[[:space:]]*([,}].*)?$/\1/p" "$CONFIG_FILE" 2>/dev/null | head -1)
    [ -n "$v" ] && echo "$v" || echo "$d"
}

cfg_set_bool() {
    local _k="$1" _v="$2" _rc
    [ -f "$CONFIG_FILE" ] || return 1

    awk -v k="$_k" -v v="$_v" '
        function q(str) { return "\"" str "\"" }
        {
            if (!done && index($0, q(k)) > 0) {
                pat = q(k) "[ \t]*:[ \t]*"
                if (match($0, pat)) {
                    pre = substr($0, 1, RSTART + RLENGTH - 1)
                    tail = substr($0, RSTART + RLENGTH)
                    sub(/^(true|false)/, "", tail)
                    print pre v tail
                    done = 1
                    next
                }
            }
            print
        }
        END { if (!done) exit 7 }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null
    _rc=$?

    if [ "$_rc" = "0" ]; then
        if [ -s "$CONFIG_FILE.tmp" ]; then
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            chmod 0644 "$CONFIG_FILE" 2>/dev/null
            return 0
        fi
        rm -f "$CONFIG_FILE.tmp"
        return 1
    elif [ "$_rc" != "7" ]; then
        rm -f "$CONFIG_FILE.tmp"
        return 1
    fi

    rm -f "$CONFIG_FILE.tmp"
    awk -v k="$_k" -v v="$_v" '
        { text = text $0 "\n" }
        END {
            sub(/[ \t\r\n]+$/, "", text)
            if (text !~ /^ *\{/ || text !~ /} *$/) exit 1
            sub(/} *$/, "", text)
            sub(/[ \t\r\n]+$/, "", text)
            if (text !~ /\{$/) text = text ","
            printf "%s\n  \"%s\": %s\n}\n", text, k, v
        }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || {
        rm -f "$CONFIG_FILE.tmp"; return 1;
    }
    [ -s "$CONFIG_FILE.tmp" ] || return 1
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE" || return 1
    chmod 0644 "$CONFIG_FILE" 2>/dev/null

}

