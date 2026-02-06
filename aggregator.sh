#!/usr/bin/env bash
#===============================================================================
#
#     ███████╗ █████╗  ██████╗  ██████╗
#     ██╔════╝██╔══██╗██╔════╝ ██╔════╝
#     █████╗  ███████║██║  ███╗██║  ███╗
#     ██╔══╝  ██╔══██║██║   ██║██║   ██║
#     ██║     ██║  ██║╚██████╔╝╚██████╔╝
#     ╚═╝     ╚═╝  ╚═╝ ╚═════╝  ╚═════╝
#
#     FILE: fagg — File Aggregator v4.1.0
#     DESC: Read-only code aggregation with token budgeting,
#           secret detection, dependency awareness, and smart splitting.
#
#     SAFETY MANIFEST:
#       ✅ READ source files      ✅ CREATE new output files
#       ❌ DELETE anything         ❌ MODIFY source files
#       ❌ MOVE/RENAME files       ❌ CHANGE permissions
#
#===============================================================================

# Strict mode — but handle arithmetic carefully to avoid (()) exit traps
set -uo pipefail

# We do NOT use set -e globally. Instead we handle errors explicitly.
# Reason: ((var++)) returns 1 when var=0, which kills functions under set -e.

#-------------------------------------------------------------------------------
# METADATA
#-------------------------------------------------------------------------------
readonly VERSION="4.1.0"
readonly PROG="fagg"
readonly RELEASE_DATE="2026-02-06"

#-------------------------------------------------------------------------------
# CONFIGURATION DEFAULTS
#-------------------------------------------------------------------------------
INPUT_DIR=""
OUTPUT_FILE=""
INCLUDE_EXTS=""
EXCLUDE_EXTS=""
EXCLUDE_DIRS="node_modules,.git,__pycache__,dist,build,.vscode,.idea,venv,.next,.nuxt,target,.cache,coverage,.tox,.svn,.hg,bower_components,.parcel-cache,.turbo,.gradle,.cargo"
MAX_FILE_SIZE="10M"
OUTPUT_FORMAT="text"

# Token controls
MAX_TOKENS=0                  # Total token budget (0 = unlimited)
MAX_FILE_TOKENS=0             # Per-source-file cap (0 = unlimited)
SPLIT_TOKENS=0                # Per-output-part token limit
OVERFLOW=3000                 # Tolerance above budget before skipping

# Behavior flags
RECENT_COUNT=0
SINCE_DATE=""
DRY_RUN=false
VERBOSE=false
LIST_ONLY=false
LINE_NUMBERS=false
SHOW_STATS=false

# Sprint 1 features
CLIPBOARD=false
DIFF_BRANCH=""
PRIORITY_BOOST=""             # Glob patterns (comma-separated)
CHECK_SECRETS=false

# Sprint 2 features
FOLLOW_IMPORTS=false
SHOW_CHECKSUMS=false

# Default binary/asset extensions to always exclude
readonly DEFAULT_EXCLUDE_EXTS="png,jpg,jpeg,gif,bmp,svg,ico,webp,tiff,mp3,mp4,avi,mov,mkv,wav,ogg,webm,flac,zip,tar,gz,bz2,xz,rar,7z,zst,pdf,doc,docx,xls,xlsx,ppt,pptx,exe,dll,so,dylib,bin,o,a,class,pyc,pyo,woff,woff2,ttf,eot,otf,db,sqlite,sqlite3,DS_Store,lock,swp,swo,bak,map"

# Secret detection patterns
readonly SECRET_PATTERNS=(
    'AKIA[0-9A-Z]{16}'                                          # AWS Access Key
    'ASIA[0-9A-Z]{16}'                                          # AWS Temp Key
    '(?i)(aws_secret_access_key|aws_secret)\s*[=:]\s*\S+'       # AWS Secret
    '(?i)(api[_-]?key|apikey|api[_-]?secret)\s*[=:]\s*["\x27]\S+' # Generic API Key
    '(?i)(password|passwd|pwd)\s*[=:]\s*["\x27]\S+'              # Passwords
    '(?i)(secret|token|private[_-]?key)\s*[=:]\s*["\x27]\S+'    # Generic Secrets
    'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}'             # JWT Tokens
    '-----BEGIN\s+(RSA\s+|EC\s+|DSA\s+)?PRIVATE\s+KEY-----'     # Private Keys
    'ghp_[A-Za-z0-9_]{36}'                                      # GitHub PAT
    'sk-[A-Za-z0-9]{48}'                                        # OpenAI Key
    'sk-ant-[A-Za-z0-9_-]{90,}'                                 # Anthropic Key
)

# Runtime state — global arrays (avoids subshell variable loss)
declare -a COLLECTED_FILES=()
declare -a SELECTED_FILES=()
declare -a SECRET_WARNINGS=()
declare -a IMPORT_ADDITIONS=()

# Runtime statistics
declare -i STAT_FILES=0
declare -i STAT_TOKENS=0
declare -i STAT_BYTES=0
declare -i STAT_SKIPPED=0
declare -i STAT_SECRETS=0
declare -i STAT_IMPORTS_ADDED=0
declare -i START_TIME=0

#-------------------------------------------------------------------------------
# TERMINAL COLORS
#-------------------------------------------------------------------------------
if [[ -t 2 ]]; then
    R=$'\033[0;31m';  G=$'\033[0;32m';  Y=$'\033[1;33m'
    B=$'\033[0;34m';  C=$'\033[0;36m';  M=$'\033[0;35m'
    DIM=$'\033[2m';   BOLD=$'\033[1m';  NC=$'\033[0m'
else
    R="" G="" Y="" B="" C="" M="" DIM="" BOLD="" NC=""
fi

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
info()    { echo -e "${B}[INFO]${NC}  $*" >&2; }
warn()    { echo -e "${Y}[WARN]${NC}  $*" >&2; }
err()     { echo -e "${R}[ERROR]${NC} $*" >&2; exit 1; }
debug()   { [[ "$VERBOSE" == "true" ]] && echo -e "${C}[DEBUG]${NC} $*" >&2 || true; }
success() { echo -e "${G}[OK]${NC}    $*" >&2; }

#-------------------------------------------------------------------------------
# TOKEN ESTIMATION (~4 chars per token, GPT-style BPE)
#-------------------------------------------------------------------------------
estimate_file_tokens() {
    local file="$1"
    local chars=0
    if [[ -r "$file" ]]; then
        chars=$(wc -c < "$file" 2>/dev/null) || chars=0
        # wc may have leading whitespace on some systems
        chars=$(echo "$chars" | tr -d ' ')
    fi
    echo $(( (chars + 3) / 4 ))
}

format_tokens() {
    local t=$1
    if (( t >= 1000000 )); then
        printf "%.1fM" "$(echo "scale=1; $t / 1000000" | bc 2>/dev/null || echo "$t")"
    elif (( t >= 1000 )); then
        echo "$(( t / 1000 ))k"
    else
        echo "$t"
    fi
}

human_size() {
    numfmt --to=iec "$1" 2>/dev/null || echo "${1}B"
}

#-------------------------------------------------------------------------------
# FILE MODIFICATION TIME (returns epoch seconds + human readable)
#-------------------------------------------------------------------------------
file_mtime_epoch() {
    stat -c '%Y' "$1" 2>/dev/null || echo "0"
}

file_mtime_human() {
    # stat -c '%y' gives human readable on Linux
    stat -c '%y' "$1" 2>/dev/null | cut -d'.' -f1 || echo "unknown"
}

#-------------------------------------------------------------------------------
# SAFETY VALIDATION
#-------------------------------------------------------------------------------
validate() {
    [[ -z "$INPUT_DIR" ]] && err "Input directory required. Use --help for usage."
    [[ ! -d "$INPUT_DIR" ]] && err "Not a directory: $INPUT_DIR"
    [[ ! -r "$INPUT_DIR" ]] && err "Cannot read directory: $INPUT_DIR"

    # Resolve to absolute path
    INPUT_DIR=$(cd "$INPUT_DIR" && pwd)

    if [[ "$LIST_ONLY" == "false" && -z "$OUTPUT_FILE" ]]; then
        err "Output file required (or use --list)"
    fi

    if [[ -n "$OUTPUT_FILE" ]]; then
        local out_dir
        out_dir=$(dirname "$OUTPUT_FILE")
        [[ ! -d "$out_dir" ]] && err "Output directory not found: $out_dir"
        [[ ! -w "$out_dir" ]] && err "Cannot write to: $out_dir"

        # Resolve output to absolute path
        OUTPUT_FILE="$(cd "$out_dir" && pwd)/$(basename "$OUTPUT_FILE")"

        # SAFETY: prevent output inside input (feedback loop)
        local abs_in abs_out_dir
        abs_in=$(realpath "$INPUT_DIR" 2>/dev/null || echo "$INPUT_DIR")
        abs_out_dir=$(realpath "$out_dir" 2>/dev/null || echo "$out_dir")
        if [[ "$abs_out_dir" == "$abs_in"* && "$abs_out_dir" != "$abs_in" ]]; then
            err "SAFETY: Output cannot be inside input directory"
        fi
    fi

    # Validate diff branch exists
    if [[ -n "$DIFF_BRANCH" ]]; then
        if ! command -v git &>/dev/null; then
            err "--diff requires git"
        fi
        if ! git -C "$INPUT_DIR" rev-parse --verify "$DIFF_BRANCH" &>/dev/null; then
            err "Git branch/ref not found: $DIFF_BRANCH"
        fi
    fi
}

#-------------------------------------------------------------------------------
# CONFIG FILE LOADING (.faggrc)
#
# Searches for .faggrc in: INPUT_DIR → parent dirs → ~/.faggrc
# Format: key=value (one per line, # comments)
#-------------------------------------------------------------------------------
load_config() {
    local config_file=""

    # Search upward from input dir
    if [[ -n "$INPUT_DIR" && -d "$INPUT_DIR" ]]; then
        local search_dir
        search_dir=$(realpath "$INPUT_DIR" 2>/dev/null || echo "$INPUT_DIR")
        while [[ "$search_dir" != "/" && -n "$search_dir" ]]; do
            if [[ -f "$search_dir/.faggrc" ]]; then
                config_file="$search_dir/.faggrc"
                break
            fi
            local prev_dir="$search_dir"
            search_dir=$(dirname "$search_dir")
            [[ "$search_dir" == "$prev_dir" ]] && break
        done
    fi

    # Fallback to home directory
    [[ -z "$config_file" && -f "$HOME/.faggrc" ]] && config_file="$HOME/.faggrc"

    [[ -z "$config_file" ]] && return 0

    debug "Loading config: $config_file"

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Only apply if not already set via CLI (CLI takes precedence)
        case "$key" in
            include)
                [[ -z "$INCLUDE_EXTS" ]] && INCLUDE_EXTS="$value"
                ;;
            exclude)
                [[ -z "$EXCLUDE_EXTS" ]] && EXCLUDE_EXTS="$value"
                ;;
            exclude-dirs)
                EXCLUDE_DIRS="$value"
                ;;
            max-tokens)
                (( MAX_TOKENS == 0 )) && MAX_TOKENS="$value"
                ;;
            max-file-tokens)
                (( MAX_FILE_TOKENS == 0 )) && MAX_FILE_TOKENS="$value"
                ;;
            split-tokens)
                (( SPLIT_TOKENS == 0 )) && SPLIT_TOKENS="$value"
                ;;
            overflow)
                OVERFLOW="$value"
                ;;
            max-size)
                MAX_FILE_SIZE="$value"
                ;;
            format)
                OUTPUT_FORMAT="$value"
                ;;
            priority-boost)
                [[ -z "$PRIORITY_BOOST" ]] && PRIORITY_BOOST="$value"
                ;;
            check-secrets)
                [[ "$value" == "true" ]] && CHECK_SECRETS=true
                ;;
            follow-imports)
                [[ "$value" == "true" ]] && FOLLOW_IMPORTS=true
                ;;
            checksums)
                [[ "$value" == "true" ]] && SHOW_CHECKSUMS=true
                ;;
            line-numbers)
                [[ "$value" == "true" ]] && LINE_NUMBERS=true
                ;;
        esac
    done < "$config_file"

    info "Config loaded: $config_file"
}

#-------------------------------------------------------------------------------
# FILE FILTERING
#-------------------------------------------------------------------------------
normalize_ext() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^\.//' | xargs
}

is_excluded_dir() {
    local path="$1"
    local IFS=','
    for d in $EXCLUDE_DIRS; do
        d=$(echo "$d" | xargs)
        [[ "$path" == *"/$d/"* || "$path" == *"/$d" ]] && return 0
    done
    return 1
}

should_include_file() {
    local file="$1"
    local name ext

    name=$(basename "$file")
    ext="${name##*.}"
    ext=$(normalize_ext "$ext")

    # Skip output file itself
    if [[ -n "$OUTPUT_FILE" ]]; then
        [[ "$file" == "$OUTPUT_FILE" ]] && return 1
        # Skip part files too
        local base="${OUTPUT_FILE%.*}"
        [[ "$file" == "${base}_part"* ]] && return 1
    fi

    # Size check
    local size=0
    size=$(stat -c%s "$file" 2>/dev/null) || size=0
    local max_bytes=10485760
    max_bytes=$(numfmt --from=iec "$MAX_FILE_SIZE" 2>/dev/null) || max_bytes=10485760
    (( size > max_bytes )) && return 1

    # Include filter (whitelist)
    if [[ -n "$INCLUDE_EXTS" ]]; then
        local found=false
        local IFS=','
        for inc in $INCLUDE_EXTS; do
            inc=$(normalize_ext "$inc")
            [[ "$ext" == "$inc" ]] && { found=true; break; }
        done
        [[ "$found" == "false" ]] && return 1
    fi

    # Exclude filter (user-specified blacklist)
    if [[ -n "$EXCLUDE_EXTS" ]]; then
        local IFS=','
        for exc in $EXCLUDE_EXTS; do
            exc=$(normalize_ext "$exc")
            [[ "$ext" == "$exc" ]] && return 1
        done
    fi

    # Default exclude (binary/assets) — only when no explicit include is set
    if [[ -z "$INCLUDE_EXTS" ]]; then
        local IFS=','
        for exc in $DEFAULT_EXCLUDE_EXTS; do
            [[ "$ext" == "$exc" ]] && return 1
        done
    fi

    # Binary detection (null bytes in first 8KB)
    if head -c 8192 "$file" 2>/dev/null | grep -qP '\x00'; then
        debug "Skip binary: $name"
        return 1
    fi

    # Date filter
    if [[ -n "$SINCE_DATE" ]]; then
        local file_epoch since_epoch
        file_epoch=$(file_mtime_epoch "$file")
        since_epoch=$(date -d "$SINCE_DATE" +%s 2>/dev/null) || since_epoch=0
        (( file_epoch < since_epoch )) && return 1
    fi

    return 0
}

#-------------------------------------------------------------------------------
# FILE COLLECTION
#
# Populates global COLLECTED_FILES array, sorted by mtime (newest first).
#-------------------------------------------------------------------------------
collect_files() {
    COLLECTED_FILES=()

    if [[ -n "$DIFF_BRANCH" ]]; then
        # Git diff mode: only files changed vs branch
        collect_diff_files
        return
    fi

    # Standard collection: find + sort by mtime
    while IFS= read -r line; do
        local filepath="${line#* }"   # Remove epoch prefix
        [[ -z "$filepath" ]] && continue

        is_excluded_dir "$filepath" && continue
        should_include_file "$filepath" || continue

        COLLECTED_FILES+=("$filepath")
    done < <(find "$INPUT_DIR" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn)

    # Apply recent count limit
    if (( RECENT_COUNT > 0 && ${#COLLECTED_FILES[@]} > RECENT_COUNT )); then
        COLLECTED_FILES=("${COLLECTED_FILES[@]:0:$RECENT_COUNT}")
    fi
}

#-------------------------------------------------------------------------------
# SPRINT 1: GIT DIFF COLLECTION
#
# Only aggregate files changed relative to a branch/ref.
#-------------------------------------------------------------------------------
collect_diff_files() {
    info "Diff mode: comparing against '$DIFF_BRANCH'"

    local changed_files=()
    while IFS= read -r relpath; do
        [[ -z "$relpath" ]] && continue
        local fullpath="$INPUT_DIR/$relpath"
        [[ -f "$fullpath" ]] || continue
        is_excluded_dir "$fullpath" && continue
        should_include_file "$fullpath" || continue
        changed_files+=("$fullpath")
    done < <(git -C "$INPUT_DIR" diff --name-only "$DIFF_BRANCH" 2>/dev/null)

    # Sort by mtime (newest first)
    local sorted=()
    while IFS= read -r line; do
        sorted+=("${line#* }")
    done < <(
        for f in "${changed_files[@]}"; do
            echo "$(file_mtime_epoch "$f") $f"
        done | sort -rn
    )

    COLLECTED_FILES=("${sorted[@]}")

    if (( RECENT_COUNT > 0 && ${#COLLECTED_FILES[@]} > RECENT_COUNT )); then
        COLLECTED_FILES=("${COLLECTED_FILES[@]:0:$RECENT_COUNT}")
    fi

    info "Found ${#COLLECTED_FILES[@]} changed files vs '$DIFF_BRANCH'"
}

#-------------------------------------------------------------------------------
# SPRINT 1: PRIORITY BOOST
#
# Ensures files matching boost patterns are always included first,
# regardless of recency or budget order.
#-------------------------------------------------------------------------------
apply_priority_boost() {
    [[ -z "$PRIORITY_BOOST" ]] && return 0

    local boosted=()
    local remaining=()

    for file in "${COLLECTED_FILES[@]}"; do
        local name
        name=$(basename "$file")
        local is_boosted=false

        local IFS=','
        for pattern in $PRIORITY_BOOST; do
            pattern=$(echo "$pattern" | xargs)
            # Use bash pattern matching
            if [[ "$name" == $pattern || "$file" == *"$pattern"* ]]; then
                is_boosted=true
                break
            fi
        done

        if [[ "$is_boosted" == "true" ]]; then
            boosted+=("$file")
            debug "Priority boost: $name"
        else
            remaining+=("$file")
        fi
    done

    if (( ${#boosted[@]} > 0 )); then
        info "Priority boost: ${#boosted[@]} files moved to front"
        # Boosted files go first, then remaining (still sorted by mtime)
        COLLECTED_FILES=("${boosted[@]}" "${remaining[@]}")
    fi
}

#-------------------------------------------------------------------------------
# SPRINT 2: DEPENDENCY CHAIN (import/require detection)
#
# Scans selected files for import statements and adds imported files
# if they exist in the project but aren't already selected.
#-------------------------------------------------------------------------------
resolve_imports() {
    [[ "$FOLLOW_IMPORTS" != "true" ]] && return 0

    info "Resolving import dependencies..."

    local already_selected=()
    for f in "${COLLECTED_FILES[@]}"; do
        already_selected+=("$f")
    done

    local additions=()

    for file in "${COLLECTED_FILES[@]}"; do
        local dir
        dir=$(dirname "$file")

        # Extract import paths from JS/TS/Python
        local imports=()
        while IFS= read -r import_path; do
            [[ -z "$import_path" ]] && continue
            imports+=("$import_path")
        done < <(
            # JS/TS: import ... from './path' or require('./path')
            grep -oP "(?:from|require\()\s*['\"]([./][^'\"]+)['\"]" "$file" 2>/dev/null | \
                grep -oP "['\"]([./][^'\"]+)['\"]" | tr -d "\"'" || true
        )

        for imp in "${imports[@]}"; do
            # Resolve relative path
            local resolved=""
            local candidates=(
                "$dir/$imp"
                "$dir/${imp}.ts"
                "$dir/${imp}.tsx"
                "$dir/${imp}.js"
                "$dir/${imp}.jsx"
                "$dir/${imp}/index.ts"
                "$dir/${imp}/index.tsx"
                "$dir/${imp}/index.js"
            )

            for candidate in "${candidates[@]}"; do
                if [[ -f "$candidate" ]]; then
                    resolved=$(realpath "$candidate" 2>/dev/null || echo "$candidate")
                    break
                fi
            done

            [[ -z "$resolved" ]] && continue

            # Check if already in list
            local already=false
            for sel in "${already_selected[@]}" "${additions[@]}"; do
                [[ "$sel" == "$resolved" ]] && { already=true; break; }
            done

            if [[ "$already" == "false" ]] && should_include_file "$resolved"; then
                additions+=("$resolved")
                already_selected+=("$resolved")
                debug "  Import found: $(basename "$file") → $(basename "$resolved")"
            fi
        done
    done

    if (( ${#additions[@]} > 0 )); then
        STAT_IMPORTS_ADDED=${#additions[@]}
        info "Added ${#additions[@]} imported dependencies"
        COLLECTED_FILES+=("${additions[@]}")
    fi
}

#-------------------------------------------------------------------------------
# TOKEN BUDGET SELECTION
#
# Processes COLLECTED_FILES → SELECTED_FILES based on token budget.
# Uses greedy fill: newest first, skip if too large, keep checking smaller.
#
# CRITICAL FIX: No ((var++)) on zero-value variables (bash exit code trap)
#-------------------------------------------------------------------------------
select_within_budget() {
    SELECTED_FILES=()

    if (( MAX_TOKENS == 0 )); then
        # No budget constraint — select all
        SELECTED_FILES=("${COLLECTED_FILES[@]}")
        return 0
    fi

    local budget=$MAX_TOKENS
    local current=0
    local skipped=0

    for file in "${COLLECTED_FILES[@]}"; do
        local ftokens=0
        ftokens=$(estimate_file_tokens "$file")

        # Apply per-file cap for budget calculation
        if (( MAX_FILE_TOKENS > 0 && ftokens > MAX_FILE_TOKENS )); then
            ftokens=$MAX_FILE_TOKENS
        fi

        local projected=$(( current + ftokens ))

        if (( projected <= budget )); then
            # Fits within budget
            SELECTED_FILES+=("$file")
            current=$projected
            debug "  + $(basename "$file") (${ftokens} tok → ${current}/${budget})"
        elif (( projected <= budget + OVERFLOW )); then
            # Slightly over but within tolerance
            SELECTED_FILES+=("$file")
            current=$projected
            debug "  + $(basename "$file") (${ftokens} tok → ${current}/${budget} overflow OK)"
        else
            # Too far over — skip but keep checking (smaller files might fit)
            skipped=$(( skipped + 1 ))  # SAFE: avoids ((skipped++)) trap
            debug "  - SKIP $(basename "$file") (${ftokens} tok, would exceed by $(( projected - budget )))"
        fi
    done

    if (( skipped > 0 )); then
        info "Skipped $skipped files (exceeded token budget)"
    fi
    info "Selected ${#SELECTED_FILES[@]} files (~${current} tokens within ${budget} budget)"
}

#-------------------------------------------------------------------------------
# SPRINT 1: SECRET DETECTION
#
# Scans selected files for potential secrets/keys before aggregation.
# Does NOT modify files — only warns.
#-------------------------------------------------------------------------------
scan_for_secrets() {
    [[ "$CHECK_SECRETS" != "true" ]] && return 0

    info "Scanning for secrets..."
    SECRET_WARNINGS=()

    for file in "${SELECTED_FILES[@]}"; do
        local rel="${file#${INPUT_DIR}/}"

        for pattern in "${SECRET_PATTERNS[@]}"; do
            local matches=""
            matches=$(grep -cP "$pattern" "$file" 2>/dev/null) || matches=0
            matches=$(echo "$matches" | tr -d ' ')

            if (( matches > 0 )); then
                SECRET_WARNINGS+=("${R}⚠ SECRET${NC} $rel: $matches match(es) for pattern")
                STAT_SECRETS=$(( STAT_SECRETS + matches ))
            fi
        done
    done

    if (( ${#SECRET_WARNINGS[@]} > 0 )); then
        echo "" >&2
        warn "═══════════════════════════════════════════════════════"
        warn "  SECRET DETECTION: ${STAT_SECRETS} potential secret(s) found!"
        warn "═══════════════════════════════════════════════════════"
        for w in "${SECRET_WARNINGS[@]}"; do
            echo -e "  $w" >&2
        done
        warn "═══════════════════════════════════════════════════════"
        echo "" >&2

        # Ask for confirmation (only if interactive)
        if [[ -t 0 && "$DRY_RUN" == "false" ]]; then
            echo -en "  ${Y}Continue anyway? (y/N):${NC} " >&2
            read -r -n 1 reply
            echo "" >&2
            if [[ ! "$reply" =~ ^[Yy]$ ]]; then
                err "Aborted due to potential secrets. Review files above."
            fi
        fi
    else
        info "No secrets detected ✓"
    fi
}

#-------------------------------------------------------------------------------
# OUTPUT WRITERS
#
# All writers operate on global SELECTED_FILES directly (no pipes/subshells).
# This ensures STAT variables are correctly updated.
#-------------------------------------------------------------------------------

get_part_filename() {
    local base="$1" part="$2"
    local name="${base%.*}"
    local ext="${base##*.}"
    [[ "$name" == "$ext" ]] && ext="txt"
    echo "${name}_part${part}.${ext}"
}

write_header() {
    local out="$1"
    local part="${2:-}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local input_name="${INPUT_DIR##*/}"

    case "$OUTPUT_FORMAT" in
        markdown)
            {
                echo "# Code Aggregation: ${input_name}"
                [[ -n "$part" ]] && echo "## Part $part"
                echo ""
                echo "| Field | Value |"
                echo "|-------|-------|"
                echo "| Source | \`${INPUT_DIR}\` |"
                echo "| Generated | $ts |"
                echo "| Tool | $PROG v$VERSION |"
                [[ -n "$DIFF_BRANCH" ]] && echo "| Diff | vs \`$DIFF_BRANCH\` |"
                echo ""
                echo "---"
            } > "$out"
            ;;
        json)
            {
                echo "{"
                echo "  \"meta\": {"
                echo "    \"source\": \"$INPUT_DIR\","
                echo "    \"date\": \"$ts\","
                echo "    \"version\": \"$VERSION\""
                [[ -n "$DIFF_BRANCH" ]] && echo "    ,\"diff_branch\": \"$DIFF_BRANCH\""
                echo "  },"
                echo "  \"files\": ["
            } > "$out"
            ;;
        *)
            {
                echo "================================================================================"
                echo "FILE AGGREGATION${part:+ — Part $part}"
                echo "Source: $INPUT_DIR"
                echo "Generated: $ts"
                echo "Tool: $PROG v$VERSION"
                [[ -n "$DIFF_BRANCH" ]] && echo "Diff: vs $DIFF_BRANCH"
                echo "================================================================================"
                echo ""
            } > "$out"
            ;;
    esac
}

write_file_content() {
    local file="$1"
    local out="$2"
    local rel_path="${file#${INPUT_DIR}/}"
    local ext="${file##*.}"

    # Read content
    local content=""
    content=$(cat "$file" 2>/dev/null) || content="[Error reading file]"

    # Token count
    local raw_chars=${#content}
    local file_tokens=$(( (raw_chars + 3) / 4 ))
    local truncated=false

    # Per-file token truncation
    if (( MAX_FILE_TOKENS > 0 && file_tokens > MAX_FILE_TOKENS )); then
        local char_limit=$(( MAX_FILE_TOKENS * 4 ))
        content="${content:0:$char_limit}"
        content="${content}"$'\n\n'"[... TRUNCATED at ~${MAX_FILE_TOKENS} tokens (original: ~${file_tokens}) ...]"
        file_tokens=$MAX_FILE_TOKENS
        truncated=true
    fi

    # Update stats (safe arithmetic)
    STAT_TOKENS=$(( STAT_TOKENS + file_tokens ))
    STAT_FILES=$(( STAT_FILES + 1 ))
    STAT_BYTES=$(( STAT_BYTES + raw_chars ))

    # Optional checksum
    local checksum=""
    if [[ "$SHOW_CHECKSUMS" == "true" ]]; then
        checksum=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1) || checksum="error"
    fi

    local trunc_label=""
    [[ "$truncated" == "true" ]] && trunc_label=" [truncated]"

    case "$OUTPUT_FORMAT" in
        markdown)
            {
                echo ""
                echo "## \`${rel_path}\` (~${file_tokens} tokens)${trunc_label}"
                [[ -n "$checksum" ]] && echo "_SHA256: \`${checksum:0:16}...\`_"
                echo ""
                echo "\`\`\`${ext}"
                if [[ "$LINE_NUMBERS" == "true" ]]; then
                    echo "$content" | cat -n
                else
                    echo "$content"
                fi
                echo "\`\`\`"
            } >> "$out"
            ;;
        json)
            {
                local escaped
                # Safe JSON escaping via python if available, fallback to sed
                if command -v python3 &>/dev/null; then
                    escaped=$(printf '%s' "$content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null) || \
                    escaped="\"[Error encoding content]\""
                else
                    escaped=$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\\' | sed 's/\\/\\n/g')
                    escaped="\"$escaped\""
                fi
                echo "    {"
                echo "      \"path\": \"${rel_path}\","
                echo "      \"tokens\": ${file_tokens},"
                echo "      \"truncated\": ${truncated},"
                [[ -n "$checksum" ]] && echo "      \"sha256\": \"${checksum}\","
                echo "      \"content\": ${escaped}"
                echo "    },"
            } >> "$out"
            ;;
        *)
            {
                echo ""
                echo "${rel_path}"
                [[ -n "$checksum" ]] && echo "# SHA256: ${checksum}"
                echo ""
                if [[ "$LINE_NUMBERS" == "true" ]]; then
                    echo "$content" | cat -n
                else
                    echo "$content"
                fi
            } >> "$out"
            ;;
    esac

    debug "Read: $rel_path (~${file_tokens} tok)"
}

write_footer() {
    local out="$1"

    case "$OUTPUT_FORMAT" in
        json)
            # Remove trailing comma, close JSON
            sed -i '$ s/,$//' "$out" 2>/dev/null || true
            {
                echo "  ],"
                echo "  \"stats\": {"
                echo "    \"files\": $STAT_FILES,"
                echo "    \"tokens\": $STAT_TOKENS,"
                echo "    \"bytes\": $STAT_BYTES"
                echo "  }"
                echo "}"
            } >> "$out"
            ;;
        markdown)
            {
                echo ""
                echo "---"
                echo "**Files:** ${STAT_FILES} | **Tokens:** ~${STAT_TOKENS} | **Read-only operation**"
            } >> "$out"
            ;;
        *)
            {
                echo ""
                echo "================================================================================"
                echo "Files: ${STAT_FILES} | Tokens: ~${STAT_TOKENS}"
                echo "================================================================================"
            } >> "$out"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# COMMAND: AGGREGATE (single output)
#-------------------------------------------------------------------------------
cmd_aggregate() {
    info "Writing ${OUTPUT_FORMAT} output..."

    write_header "$OUTPUT_FILE"

    for file in "${SELECTED_FILES[@]}"; do
        write_file_content "$file" "$OUTPUT_FILE"
    done

    write_footer "$OUTPUT_FILE"
}

#-------------------------------------------------------------------------------
# COMMAND: SPLIT BY TOKENS
#
# Each output file contains approximately SPLIT_TOKENS tokens.
# Files are kept whole (never split mid-file).
#-------------------------------------------------------------------------------
cmd_split() {
    info "Splitting output (~$(format_tokens $SPLIT_TOKENS) tokens per part)..."

    local part=1
    local part_tokens=0
    local part_files=0
    local parts_created=0
    local current_out
    current_out=$(get_part_filename "$OUTPUT_FILE" "$part")

    # Save/restore stats per part
    local saved_stat_files=$STAT_FILES
    local saved_stat_tokens=$STAT_TOKENS

    write_header "$current_out" "$part"

    for file in "${SELECTED_FILES[@]}"; do
        local ftokens
        ftokens=$(estimate_file_tokens "$file")
        if (( MAX_FILE_TOKENS > 0 && ftokens > MAX_FILE_TOKENS )); then
            ftokens=$MAX_FILE_TOKENS
        fi

        # Check if current part is full (but always put at least 1 file per part)
        if (( part_files > 0 && part_tokens + ftokens > SPLIT_TOKENS )); then
            # Finalize current part
            write_footer "$current_out"
            local psize
            psize=$(stat -c%s "$current_out" 2>/dev/null) || psize=0
            info "  Part $part: $(basename "$current_out") ($part_files files, ~${part_tokens} tok, $(human_size $psize))"
            parts_created=$(( parts_created + 1 ))

            # Start new part
            part=$(( part + 1 ))
            part_tokens=0
            part_files=0

            # Reset per-part stats
            STAT_FILES=$saved_stat_files
            STAT_TOKENS=$saved_stat_tokens

            current_out=$(get_part_filename "$OUTPUT_FILE" "$part")
            write_header "$current_out" "$part"
        fi

        write_file_content "$file" "$current_out"
        part_tokens=$(( part_tokens + ftokens ))
        part_files=$(( part_files + 1 ))

        saved_stat_files=$STAT_FILES
        saved_stat_tokens=$STAT_TOKENS
    done

    # Close final part
    if (( part_files > 0 )); then
        write_footer "$current_out"
        local psize
        psize=$(stat -c%s "$current_out" 2>/dev/null) || psize=0
        info "  Part $part: $(basename "$current_out") ($part_files files, ~${part_tokens} tok, $(human_size $psize))"
        parts_created=$(( parts_created + 1 ))
    fi

    echo "" >&2
    info "Created $parts_created part files"
}

#-------------------------------------------------------------------------------
# COMMAND: LIST
#-------------------------------------------------------------------------------
cmd_list() {
    echo "" >&2
    printf "  ${BOLD}%5s${NC} │ %10s │ %8s │ %-19s │ %s\n" "#" "SIZE" "TOKENS" "MODIFIED" "PATH"
    printf "  ─────┼────────────┼──────────┼─────────────────────┼────────────────────\n"

    local i=0
    local total_tokens=0

    for file in "${SELECTED_FILES[@]}"; do
        i=$(( i + 1 ))
        local size mtime tokens rel_path
        size=$(stat -c%s "$file" 2>/dev/null) || size=0
        mtime=$(file_mtime_human "$file")
        tokens=$(estimate_file_tokens "$file")
        rel_path="${file#${INPUT_DIR}/}"
        total_tokens=$(( total_tokens + tokens ))

        printf "  %5d │ %10s │ %8s │ %-19s │ %s\n" \
            "$i" \
            "$(human_size $size)" \
            "$(format_tokens $tokens)" \
            "$mtime" \
            "$rel_path"
    done

    printf "  ─────┼────────────┼──────────┼─────────────────────┼────────────────────\n"
    printf "  ${BOLD}Total: %d files, ~%s tokens${NC}\n\n" "$i" "$(format_tokens $total_tokens)"
}

#-------------------------------------------------------------------------------
# COMMAND: DRY RUN
#-------------------------------------------------------------------------------
cmd_dry_run() {
    echo "" >&2
    info "${BOLD}DRY RUN — files that would be included:${NC}"
    echo "" >&2

    local total_tokens=0

    for file in "${SELECTED_FILES[@]}"; do
        local size tokens mtime rel_path
        size=$(stat -c%s "$file" 2>/dev/null) || size=0
        tokens=$(estimate_file_tokens "$file")
        mtime=$(file_mtime_human "$file")
        rel_path="${file#${INPUT_DIR}/}"

        # Show truncation indicator
        local trunc=""
        if (( MAX_FILE_TOKENS > 0 && tokens > MAX_FILE_TOKENS )); then
            trunc=" ${Y}[truncate: ${tokens}→${MAX_FILE_TOKENS}]${NC}"
            tokens=$MAX_FILE_TOKENS
        fi

        total_tokens=$(( total_tokens + tokens ))
        printf "  %10s  %6s tok  %s  %s%s\n" \
            "$(human_size $size)" \
            "$(format_tokens $tokens)" \
            "$mtime" \
            "$rel_path" \
            "$trunc"
    done

    echo "" >&2
    info "Total: ${#SELECTED_FILES[@]} files, ~$(format_tokens $total_tokens) tokens"

    if (( SPLIT_TOKENS > 0 )); then
        local parts=$(( (total_tokens + SPLIT_TOKENS - 1) / SPLIT_TOKENS ))
        info "Would create ~$parts output parts (~$(format_tokens $SPLIT_TOKENS) tokens each)"
    fi
}

#-------------------------------------------------------------------------------
# SPRINT 1: CLIPBOARD
#-------------------------------------------------------------------------------
copy_to_clipboard() {
    [[ "$CLIPBOARD" != "true" ]] && return 0
    [[ ! -f "$OUTPUT_FILE" ]] && return 0

    if command -v xclip &>/dev/null; then
        cat "$OUTPUT_FILE" | xclip -selection clipboard 2>/dev/null
        success "Copied to clipboard (xclip)"
    elif command -v xsel &>/dev/null; then
        cat "$OUTPUT_FILE" | xsel --clipboard 2>/dev/null
        success "Copied to clipboard (xsel)"
    elif command -v wl-copy &>/dev/null; then
        cat "$OUTPUT_FILE" | wl-copy 2>/dev/null
        success "Copied to clipboard (wl-copy)"
    elif command -v clip.exe &>/dev/null; then
        # WSL clipboard support!
        cat "$OUTPUT_FILE" | clip.exe 2>/dev/null
        success "Copied to clipboard (clip.exe/WSL)"
    elif command -v pbcopy &>/dev/null; then
        cat "$OUTPUT_FILE" | pbcopy 2>/dev/null
        success "Copied to clipboard (pbcopy/macOS)"
    else
        warn "Clipboard not available. Install xclip, xsel, or use WSL's clip.exe"
    fi
}

#-------------------------------------------------------------------------------
# EXTENSION STATS
#-------------------------------------------------------------------------------
show_ext_stats() {
    [[ "$SHOW_STATS" != "true" ]] && return 0

    echo "" >&2
    info "Extension breakdown:"
    printf "  %8s  %8s  %s\n" "FILES" "TOKENS" "EXT" >&2
    printf "  %8s  %8s  %s\n" "─────" "──────" "───" >&2

    # Group by extension
    declare -A ext_count
    declare -A ext_tokens

    for file in "${SELECTED_FILES[@]}"; do
        local ext="${file##*.}"
        ext=$(normalize_ext "$ext")
        local tok
        tok=$(estimate_file_tokens "$file")

        ext_count[$ext]=$(( ${ext_count[$ext]:-0} + 1 ))
        ext_tokens[$ext]=$(( ${ext_tokens[$ext]:-0} + tok ))
    done

    # Sort by token count descending
    for ext in "${!ext_tokens[@]}"; do
        echo "${ext_tokens[$ext]} ${ext_count[$ext]} $ext"
    done | sort -rn | while read -r tok cnt ext; do
        printf "  %8d  %8s  .%s\n" "$cnt" "$(format_tokens $tok)" "$ext" >&2
    done
}

#-------------------------------------------------------------------------------
# BANNER & RESULTS
#-------------------------------------------------------------------------------
show_banner() {
    echo "" >&2
    echo "  ${BOLD}${PROG} v${VERSION}${NC} — File Content Aggregator" >&2
    echo "  ──────────────────────────────────────────────" >&2
    echo "  Source:    ${INPUT_DIR}" >&2
    [[ -n "$OUTPUT_FILE" ]]    && echo "  Output:    ${OUTPUT_FILE}" >&2
    echo "  Format:    ${OUTPUT_FORMAT}" >&2
    [[ -n "$INCLUDE_EXTS" ]]   && echo "  Include:   ${INCLUDE_EXTS}" >&2
    [[ -n "$EXCLUDE_EXTS" ]]   && echo "  Exclude:   ${EXCLUDE_EXTS}" >&2
    (( RECENT_COUNT > 0 ))     && echo "  Recent:    top ${RECENT_COUNT} files" >&2
    (( MAX_TOKENS > 0 ))       && echo "  Budget:    $(format_tokens $MAX_TOKENS) tokens (±${OVERFLOW} overflow)" >&2
    (( MAX_FILE_TOKENS > 0 ))  && echo "  Per-file:  max $(format_tokens $MAX_FILE_TOKENS) tokens" >&2
    (( SPLIT_TOKENS > 0 ))     && echo "  Split:     ~$(format_tokens $SPLIT_TOKENS) tokens per part" >&2
    [[ -n "$DIFF_BRANCH" ]]    && echo "  Diff:      vs ${DIFF_BRANCH}" >&2
    [[ -n "$PRIORITY_BOOST" ]] && echo "  Boost:     ${PRIORITY_BOOST}" >&2
    [[ "$CHECK_SECRETS" == "true" ]]  && echo "  Secrets:   scanning enabled" >&2
    [[ "$FOLLOW_IMPORTS" == "true" ]] && echo "  Imports:   follow enabled" >&2
    echo "  Safety:    read-only (source files never modified)" >&2
    echo "" >&2
}

show_results() {
    local elapsed=$(( $(date +%s) - START_TIME ))

    echo "" >&2
    success "Done in ${elapsed}s"
    if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
        local out_size
        out_size=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null) || out_size=0
        info "Output:   ${OUTPUT_FILE} ($(human_size $out_size))"
    fi
    info "Tokens:   ~${STAT_TOKENS}"
    info "Files:    ${STAT_FILES}"
    (( STAT_SKIPPED > 0 ))       && info "Skipped:  ${STAT_SKIPPED}"
    (( STAT_SECRETS > 0 ))       && warn "Secrets:  ${STAT_SECRETS} potential leak(s) in output"
    (( STAT_IMPORTS_ADDED > 0 )) && info "Imports:  ${STAT_IMPORTS_ADDED} dependencies auto-added"
    echo "" >&2
}

#-------------------------------------------------------------------------------
# HELP & VERSION
#-------------------------------------------------------------------------------
show_version() {
    echo "$PROG v$VERSION ($RELEASE_DATE)"
    echo "Safety: READ-ONLY on source files"
    echo ""
    echo "Allowed: Read files, Create new output files"
    echo "Blocked: Delete, Modify, Move, Rename, Change permissions"
}

show_help() {
    cat << 'EOF'
USAGE:
    fagg <input_dir> <output_file> [OPTIONS]
    fagg <input_dir> --list [OPTIONS]
    fagg --help | --version

FILTERING:
    -i, --include <exts>        Include only these extensions    "ts,tsx,json"
    -e, --exclude <exts>        Exclude these extensions         "log,tmp,bak"
    -d, --exclude-dirs <dirs>   Exclude directories              "tests,fixtures"
    -s, --max-size <size>       Max source file size             (default: 10M)
    --since <date>              Files modified after date        "2025-01-01"

TOKEN CONTROLS:
    --max-tokens <n>            Total token budget. Fills with newest files
                                until budget is approximately reached.
                                Files are kept WHOLE (never truncated mid-file
                                unless exceeding overflow tolerance).

    --max-file-tokens <n>       Truncate individual source files at N tokens.
                                Adds [TRUNCATED] marker at cut point.

    --split-tokens <n>          Split output into multiple files, each ~N tokens.
                                Creates: output_part1.txt, output_part2.txt, ...

    --overflow <n>              Tokens over budget before skipping (default: 3000)

    -r, --recent <n>            Pre-filter: only N most recent files BEFORE
                                applying token budget.

GIT INTEGRATION:
    --diff <branch>             Only aggregate files changed vs branch/ref.
                                Example: --diff main, --diff HEAD~5

SMART SELECTION:
    --priority-boost <patterns> Always include matching files first.
                                Comma-separated globs.
                                Example: "*.config.*,schema.prisma,package.json"

    --follow-imports            Parse import/require statements and auto-include
                                imported files even if not recently modified.

SAFETY:
    --check-secrets             Scan for API keys, tokens, passwords before
                                writing output. Prompts for confirmation.

OUTPUT:
    -f, --format <fmt>          text (default), markdown, json
    -n, --line-numbers          Add line numbers to content
    --checksums                 Include SHA256 hash per file
    --stats                     Extension breakdown after processing
    --clipboard                 Copy output to clipboard (WSL: clip.exe)

MODES:
    --list                      List matching files with metadata
    --dry-run                   Preview what would be processed
    --verbose                   Debug logging

CONFIG FILE (.faggrc):
    Place in project root or ~/.faggrc. CLI flags override config values.

    # .faggrc example
    include=ts,tsx,json,css,md
    max-tokens=50000
    max-file-tokens=5000
    exclude-dirs=tests,mocks,fixtures
    format=markdown
    check-secrets=true
    follow-imports=true
    priority-boost=package.json,tsconfig.json

EXAMPLES:
    # Fill ~50k tokens with latest code
    fagg ./src out.txt -i "ts,tsx" --max-tokens 50000

    # Multi-part: ~50k per part, 700k total, files capped at 5k tokens
    fagg ./src out.txt --split-tokens 50000 --max-tokens 700000 --max-file-tokens 5000

    # Only files changed vs main branch
    fagg ./src out.txt --diff main -i "ts,tsx" --clipboard

    # Recent 20 files, auto-include imports, check secrets
    fagg ./src out.txt -r 20 --follow-imports --check-secrets

    # Always include config files even if old
    fagg ./src out.txt --max-tokens 50000 --priority-boost "*.config.*,package.json"

    # Preview with dry run
    fagg ./src out.txt --max-tokens 50000 --dry-run --verbose

TOKEN BUDGET LOGIC:
    Files sorted newest → oldest, then selected greedily:
      1. File fits within budget          → INCLUDE
      2. File over by ≤ overflow (3000)   → INCLUDE (slight overshoot OK)
      3. File over by > overflow          → SKIP (but keep checking smaller)
    This keeps output close to budget while preserving whole files.

EXIT CODES:
    0   Success
    1   Error (missing args, invalid path, etc.)
EOF
}

#-------------------------------------------------------------------------------
# ARGUMENT PARSING
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)           show_help; exit 0 ;;
            -v|--version)        show_version; exit 0 ;;
            -i|--include)        INCLUDE_EXTS="$2"; shift 2 ;;
            -e|--exclude)        EXCLUDE_EXTS="$2"; shift 2 ;;
            -d|--exclude-dirs)   EXCLUDE_DIRS="$2"; shift 2 ;;
            -s|--max-size)       MAX_FILE_SIZE="$2"; shift 2 ;;
            -r|--recent)         RECENT_COUNT="$2"; shift 2 ;;
            -f|--format)         OUTPUT_FORMAT="$2"; shift 2 ;;
            -n|--line-numbers)   LINE_NUMBERS=true; shift ;;
            --max-tokens)        MAX_TOKENS="$2"; shift 2 ;;
            --max-file-tokens)   MAX_FILE_TOKENS="$2"; shift 2 ;;
            --split-tokens)      SPLIT_TOKENS="$2"; shift 2 ;;
            --overflow)          OVERFLOW="$2"; shift 2 ;;
            --since)             SINCE_DATE="$2"; shift 2 ;;
            --diff)              DIFF_BRANCH="$2"; shift 2 ;;
            --priority-boost)    PRIORITY_BOOST="$2"; shift 2 ;;
            --follow-imports)    FOLLOW_IMPORTS=true; shift ;;
            --check-secrets)     CHECK_SECRETS=true; shift ;;
            --checksums)         SHOW_CHECKSUMS=true; shift ;;
            --clipboard)         CLIPBOARD=true; shift ;;
            --list)              LIST_ONLY=true; shift ;;
            --dry-run)           DRY_RUN=true; shift ;;
            --verbose)           VERBOSE=true; shift ;;
            --stats)             SHOW_STATS=true; shift ;;
            --)                  shift; break ;;
            -*)                  err "Unknown option: $1 (use --help)" ;;
            *)
                if [[ -z "$INPUT_DIR" ]]; then
                    INPUT_DIR="$1"
                elif [[ -z "$OUTPUT_FILE" ]]; then
                    OUTPUT_FILE="$1"
                else
                    err "Unexpected argument: $1"
                fi
                shift ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    START_TIME=$(date +%s)

    # 1. Parse CLI arguments
    parse_args "$@"

    # 2. Load config file (CLI overrides config)
    load_config

    # 3. Validate inputs
    validate

    # 4. Show banner
    show_banner

    # 5. Collect matching files (sorted newest first)
    info "Collecting files..."
    collect_files

    if (( ${#COLLECTED_FILES[@]} == 0 )); then
        err "No files matched criteria"
    fi
    info "Found ${#COLLECTED_FILES[@]} files"

    # 6. Apply priority boost (move boosted files to front)
    apply_priority_boost

    # 7. Resolve import dependencies (add imported files)
    resolve_imports

    # 8. Apply token budget selection
    select_within_budget

    if (( ${#SELECTED_FILES[@]} == 0 )); then
        err "No files fit within token budget (${MAX_TOKENS} tokens, ±${OVERFLOW} overflow)"
    fi

    # 9. Secret scanning
    scan_for_secrets

    # 10. Route to command
    if [[ "$LIST_ONLY" == "true" ]]; then
        cmd_list
    elif [[ "$DRY_RUN" == "true" ]]; then
        cmd_dry_run
    elif (( SPLIT_TOKENS > 0 )); then
        cmd_split
        show_results
    else
        cmd_aggregate
        show_results
    fi

    # 11. Extension stats
    show_ext_stats

    # 12. Clipboard
    copy_to_clipboard
}

main "$@"