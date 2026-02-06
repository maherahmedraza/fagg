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
#          FILE: fagg - File Aggregator
#       VERSION: 4.0.0
#         USAGE: fagg [OPTIONS] <input_dir> [output_file]
#   DESCRIPTION: Read-only code aggregation with intelligent token budgeting.
#
#   SAFETY: This tool is READ-ONLY on source files.
#           It CANNOT delete, modify, move, or copy source files.
#           The ONLY write operation is creating new output file(s).
#
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#-------------------------------------------------------------------------------
# METADATA
#-------------------------------------------------------------------------------
readonly VERSION="4.0.0"
readonly PROG="fagg"
readonly RELEASE="2025-02-07"

#-------------------------------------------------------------------------------
# DEFAULTS
#-------------------------------------------------------------------------------

INPUT_DIR=""
OUTPUT_FILE=""
INCLUDE_EXTS=""
EXCLUDE_EXTS=""
EXCLUDE_DIRS="node_modules,.git,__pycache__,dist,build,.vscode,.idea,venv,.next,.nuxt,target,.cache,coverage,.tox,.svn,.hg,bower_components,.parcel-cache,.turbo,.gradle,.cargo"
MAX_FILE_SIZE="10M"
OUTPUT_FORMAT="text"               # text | markdown | json

# Token controls
MAX_TOKENS=0                       # Total token budget (0 = unlimited)
MAX_FILE_TOKENS=0                  # Per-source-file token cap (0 = unlimited)
SPLIT_TOKENS=0                     # Per-output-part token limit (0 = single file)
OVERFLOW=3000                      # Tolerance above budget before skipping

# Behavior
RECENT_COUNT=0                     # 0 = all files (sorted by mtime anyway)
SINCE_DATE=""
DRY_RUN=false
VERBOSE=false
LIST_ONLY=false
SHOW_STATS=false
LINE_NUMBERS=false

# Default binary/asset extensions to always exclude
DEFAULT_EXCLUDE_EXTS="png,jpg,jpeg,gif,bmp,svg,ico,webp,tiff,mp3,mp4,avi,mov,mkv,wav,ogg,webm,flac,zip,tar,gz,bz2,xz,rar,7z,pdf,doc,docx,xls,xlsx,ppt,pptx,exe,dll,so,dylib,bin,o,a,class,pyc,woff,woff2,ttf,eot,otf,db,sqlite,sqlite3,DS_Store,lock,swp,swo,bak,map"

# Runtime stats
declare -i STAT_FILES=0
declare -i STAT_TOKENS=0
declare -i STAT_BYTES=0
declare -i STAT_SKIPPED=0
declare -i START_TIME=0

#-------------------------------------------------------------------------------
# TERMINAL COLORS (disabled if not interactive)
#-------------------------------------------------------------------------------
if [[ -t 2 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'
    B=$'\033[0;34m'; C=$'\033[0;36m'; DIM=$'\033[2m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    R="" G="" Y="" B="" C="" DIM="" BOLD="" NC=""
fi

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
info()  { echo "${B}[INFO]${NC}  $*" >&2; }
warn()  { echo "${Y}[WARN]${NC}  $*" >&2; }
err()   { echo "${R}[ERROR]${NC} $*" >&2; exit 1; }
debug() { [[ "$VERBOSE" == "true" ]] && echo "${C}[DEBUG]${NC} $*" >&2 || true; }

#-------------------------------------------------------------------------------
# TOKEN ESTIMATION
#
# Uses ~4 characters per token (GPT-style BPE approximation).
# For code, this tends to slightly overestimate, which is safer.
#-------------------------------------------------------------------------------
estimate_tokens_for_file() {
    local file="$1"
    local chars
    chars=$(wc -c < "$file" 2>/dev/null || echo "0")
    echo $(( (chars + 3) / 4 ))
}

estimate_tokens_for_string() {
    local str="$1"
    local chars=${#str}
    echo $(( (chars + 3) / 4 ))
}

format_tokens() {
    local t=$1
    if (( t >= 1000 )); then
        echo "$(( t / 1000 ))k"
    else
        echo "$t"
    fi
}

#-------------------------------------------------------------------------------
# SAFETY VALIDATION
#-------------------------------------------------------------------------------
validate() {
    [[ -z "$INPUT_DIR" ]] && err "Input directory required. Use --help for usage."
    [[ ! -d "$INPUT_DIR" ]] && err "Not a directory: $INPUT_DIR"
    [[ ! -r "$INPUT_DIR" ]] && err "Cannot read directory: $INPUT_DIR"

    # Resolve input to absolute
    INPUT_DIR=$(cd "$INPUT_DIR" && pwd)

    if [[ "$LIST_ONLY" == "false" && -z "$OUTPUT_FILE" ]]; then
        err "Output file required (or use --list)"
    fi

    if [[ -n "$OUTPUT_FILE" ]]; then
        local out_dir
        out_dir=$(dirname "$OUTPUT_FILE")
        [[ ! -d "$out_dir" ]] && err "Output directory not found: $out_dir"
        [[ ! -w "$out_dir" ]] && err "Cannot write to: $out_dir"

        # SAFETY: prevent output inside input
        local abs_out
        abs_out=$(realpath "$out_dir" 2>/dev/null || echo "$out_dir")
        local abs_in
        abs_in=$(realpath "$INPUT_DIR" 2>/dev/null || echo "$INPUT_DIR")
        if [[ "$abs_out" == "$abs_in"* ]]; then
            err "SAFETY: Output cannot be inside input directory (feedback loop)"
        fi
    fi
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

    # Skip output file
    if [[ -n "$OUTPUT_FILE" ]]; then
        local abs_file abs_out
        abs_file=$(realpath "$file" 2>/dev/null || echo "$file")
        abs_out=$(realpath "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
        [[ "$abs_file" == "$abs_out" ]] && return 1
    fi

    # Skip output part files too
    if [[ -n "$OUTPUT_FILE" ]]; then
        local base="${OUTPUT_FILE%.*}"
        [[ "$file" == "${base}_part"* ]] && return 1
    fi

    # Size check
    local size
    size=$(stat -c%s "$file" 2>/dev/null || echo "0")
    local max_bytes
    max_bytes=$(numfmt --from=iec "$MAX_FILE_SIZE" 2>/dev/null || echo "10485760")
    (( size > max_bytes )) && return 1

    # Include filter
    if [[ -n "$INCLUDE_EXTS" ]]; then
        local found=false
        local IFS=','
        for inc in $INCLUDE_EXTS; do
            inc=$(normalize_ext "$inc")
            [[ "$ext" == "$inc" ]] && { found=true; break; }
        done
        [[ "$found" == "false" ]] && return 1
    fi

    # Exclude filter (user-specified)
    if [[ -n "$EXCLUDE_EXTS" ]]; then
        local IFS=','
        for exc in $EXCLUDE_EXTS; do
            exc=$(normalize_ext "$exc")
            [[ "$ext" == "$exc" ]] && return 1
        done
    fi

    # Default exclude (binary/assets)
    local IFS=','
    for exc in $DEFAULT_EXCLUDE_EXTS; do
        [[ "$ext" == "$exc" ]] && return 1
    done

    # Binary detection (null bytes in first 8KB)
    if head -c 8192 "$file" 2>/dev/null | grep -qP '\x00'; then
        debug "Skip binary: $name"
        return 1
    fi

    # Date filter
    if [[ -n "$SINCE_DATE" ]]; then
        local file_epoch since_epoch
        file_epoch=$(stat -c%Y "$file" 2>/dev/null || echo "0")
        since_epoch=$(date -d "$SINCE_DATE" +%s 2>/dev/null || echo "0")
        (( file_epoch < since_epoch )) && return 1
    fi

    return 0
}

#-------------------------------------------------------------------------------
# COLLECT & SORT FILES
#
# Returns files sorted by modification time (newest first).
# This is the foundation for token-budget selection.
#-------------------------------------------------------------------------------
collect_files() {
    local input="$1"
    local files=()

    while IFS= read -r line; do
        local filepath="${line#* }"     # Remove timestamp prefix
        is_excluded_dir "$filepath" && continue
        should_include_file "$filepath" && files+=("$filepath")
    done < <(find "$input" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn)

    # Apply recent count limit if specified
    if (( RECENT_COUNT > 0 && ${#files[@]} > RECENT_COUNT )); then
        files=("${files[@]:0:$RECENT_COUNT}")
    fi

    printf '%s\n' "${files[@]}"
}

#-------------------------------------------------------------------------------
# TOKEN BUDGET SELECTION
#
# Given a list of files (already sorted newest-first), select files
# that fit within the token budget. Keeps files whole.
#
# Rules:
#   1. Process files newest → oldest
#   2. Estimate tokens for each file
#   3. If file fits within budget: include it
#   4. If file exceeds budget by <= OVERFLOW: include it (slight overshoot OK)
#   5. If file exceeds budget by > OVERFLOW: skip it, but keep checking
#      (smaller files later might still fit)
#   6. If MAX_FILE_TOKENS set, use capped size for budget calculation
#-------------------------------------------------------------------------------
select_within_budget() {
    local budget=$1
    shift
    local files=("$@")

    local selected=()
    local current_tokens=0
    local skipped=0

    for file in "${files[@]}"; do
        local file_tokens
        file_tokens=$(estimate_tokens_for_file "$file")

        # Apply per-file cap for budget calculation
        if (( MAX_FILE_TOKENS > 0 && file_tokens > MAX_FILE_TOKENS )); then
            file_tokens=$MAX_FILE_TOKENS
        fi

        local projected=$(( current_tokens + file_tokens ))

        if (( projected <= budget )); then
            # Fits within budget
            selected+=("$file")
            current_tokens=$projected
            debug "  + ${file##*/} (${file_tokens} tok, total: ${current_tokens}/${budget})"
        elif (( projected <= budget + OVERFLOW )); then
            # Slightly over but within tolerance
            selected+=("$file")
            current_tokens=$projected
            debug "  + ${file##*/} (${file_tokens} tok, overflow OK: ${current_tokens}/${budget})"
        else
            # Too far over — skip but continue (smaller files might fit)
            ((skipped++))
            debug "  - SKIP ${file##*/} (${file_tokens} tok would exceed budget by $(( projected - budget )))"
        fi
    done

    if (( skipped > 0 )); then
        info "Skipped $skipped files exceeding token budget"
    fi
    info "Selected ${#selected[@]} files (~${current_tokens} tokens within ${budget} budget)"

    printf '%s\n' "${selected[@]}"
}

#-------------------------------------------------------------------------------
# OUTPUT WRITERS
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

    case "$OUTPUT_FORMAT" in
        markdown)
            {
                echo "# Code Aggregation Report"
                [[ -n "$part" ]] && echo "## Part $part"
                echo ""
                echo "- **Source:** \`${INPUT_DIR}\`"
                echo "- **Generated:** $ts"
                echo "- **Tool:** $PROG v$VERSION"
                echo ""
                echo "---"
            } > "$out"
            ;;
        json)
            echo "{\"meta\":{\"source\":\"$INPUT_DIR\",\"date\":\"$ts\",\"version\":\"$VERSION\"${part:+,\"part\":$part}},\"files\":[" > "$out"
            ;;
        *)
            {
                echo "================================================================================"
                echo "FILE AGGREGATION REPORT${part:+ - Part $part}"
                echo "Source: $INPUT_DIR"
                echo "Generated: $ts"
                echo "Tool: $PROG v$VERSION"
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
    local content
    content=$(cat "$file" 2>/dev/null || echo "[Error reading file]")

    # Per-file token truncation
    local file_tokens
    file_tokens=$(estimate_tokens_for_string "$content")
    local truncated=false

    if (( MAX_FILE_TOKENS > 0 && file_tokens > MAX_FILE_TOKENS )); then
        local char_limit=$(( MAX_FILE_TOKENS * 4 ))
        content="${content:0:$char_limit}"
        content="$content"$'\n\n'"[... TRUNCATED at ~${MAX_FILE_TOKENS} tokens (original: ~${file_tokens} tokens) ...]"
        file_tokens=$MAX_FILE_TOKENS
        truncated=true
    fi

    ((STAT_TOKENS += file_tokens))
    ((STAT_FILES++))
    local size=${#content}
    ((STAT_BYTES += size))

    local trunc_label=""
    [[ "$truncated" == "true" ]] && trunc_label=" [truncated]"

    case "$OUTPUT_FORMAT" in
        markdown)
            {
                echo ""
                echo "## \`${rel_path}\`  (~${file_tokens} tokens)${trunc_label}"
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
            local escaped
            escaped=$(echo "$content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || \
                      echo "$content" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
            echo "{\"path\":\"${rel_path}\",\"tokens\":${file_tokens},\"truncated\":${truncated},\"content\":${escaped}}," >> "$out"
            ;;
        *)
            {
                echo ""
                echo "${rel_path}"
                echo ""
                if [[ "$LINE_NUMBERS" == "true" ]]; then
                    echo "$content" | cat -n
                else
                    echo "$content"
                fi
            } >> "$out"
            ;;
    esac
}

write_footer() {
    local out="$1"
    local files="$2"
    local tokens="$3"

    case "$OUTPUT_FORMAT" in
        json)
            # Remove trailing comma, close array
            sed -i '$ s/,$//' "$out" 2>/dev/null || true
            echo "],\"stats\":{\"files\":${files},\"tokens\":${tokens}}}" >> "$out"
            ;;
        markdown)
            {
                echo ""
                echo "---"
                echo "**Files:** ${files} | **Tokens:** ~${tokens} | **Safety:** Read-only"
            } >> "$out"
            ;;
        *)
            {
                echo ""
                echo "================================================================================"
                echo "Files: ${files} | Tokens: ~${tokens}"
                echo "================================================================================"
            } >> "$out"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# COMMAND: SINGLE OUTPUT (no splitting)
#-------------------------------------------------------------------------------
cmd_single_output() {
    local -a files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done

    (( ${#files[@]} == 0 )) && err "No files matched criteria"
    info "Processing ${#files[@]} files..."

    write_header "$OUTPUT_FILE"

    for file in "${files[@]}"; do
        write_file_content "$file" "$OUTPUT_FILE"
    done

    write_footer "$OUTPUT_FILE" "$STAT_FILES" "$STAT_TOKENS"
}

#-------------------------------------------------------------------------------
# COMMAND: SPLIT BY TOKENS
#
# Creates multiple output files, each containing approximately
# SPLIT_TOKENS tokens. Respects MAX_TOKENS as total cap.
#-------------------------------------------------------------------------------
cmd_split_output() {
    local -a files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done

    (( ${#files[@]} == 0 )) && err "No files matched criteria"

    local part=1
    local part_tokens=0
    local part_files=0
    local total_tokens=0
    local current_out
    current_out=$(get_part_filename "$OUTPUT_FILE" "$part")

    write_header "$current_out" "$part"

    info "Splitting into ~$(format_tokens $SPLIT_TOKENS)-token parts..."

    for file in "${files[@]}"; do
        local file_tokens
        file_tokens=$(estimate_tokens_for_file "$file")
        if (( MAX_FILE_TOKENS > 0 && file_tokens > MAX_FILE_TOKENS )); then
            file_tokens=$MAX_FILE_TOKENS
        fi

        # Check total budget
        if (( MAX_TOKENS > 0 && total_tokens + file_tokens > MAX_TOKENS + OVERFLOW )); then
            debug "Total budget reached at $total_tokens tokens"
            break
        fi

        # Check if current part is full
        if (( part_files > 0 && part_tokens + file_tokens > SPLIT_TOKENS )); then
            # Close current part
            write_footer "$current_out" "$part_files" "$part_tokens"
            local part_size
            part_size=$(stat -c%s "$current_out" 2>/dev/null || echo "0")
            info "  Part $part: $current_out ($part_files files, ~$part_tokens tokens, $(numfmt --to=iec "$part_size" 2>/dev/null || echo "${part_size}B"))"

            # Start new part
            ((part++))
            part_tokens=0
            part_files=0
            current_out=$(get_part_filename "$OUTPUT_FILE" "$part")
            write_header "$current_out" "$part"
        fi

        write_file_content "$file" "$current_out"
        ((part_tokens += file_tokens))
        ((part_files++))
        ((total_tokens += file_tokens))
    done

    # Close final part
    if (( part_files > 0 )); then
        write_footer "$current_out" "$part_files" "$part_tokens"
        local part_size
        part_size=$(stat -c%s "$current_out" 2>/dev/null || echo "0")
        info "  Part $part: $current_out ($part_files files, ~$part_tokens tokens, $(numfmt --to=iec "$part_size" 2>/dev/null || echo "${part_size}B"))"
    fi

    echo ""
    info "Created $part part files (~$total_tokens total tokens)"
}

#-------------------------------------------------------------------------------
# COMMAND: LIST FILES
#-------------------------------------------------------------------------------
cmd_list() {
    local -a files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done

    (( ${#files[@]} == 0 )) && { info "No files matched criteria"; return; }

    # Header
    printf "\n  ${BOLD}%5s${NC} | %10s | %8s | %-19s | %s\n" "#" "SIZE" "TOKENS" "MODIFIED" "PATH"
    printf "  %s\n" "------+------------+----------+---------------------+------------------------------------------"

    local i=0 total_tokens=0
    for file in "${files[@]}"; do
        ((i++))
        local size mtime tokens rel_path
        size=$(stat -c%s "$file" 2>/dev/null || echo "0")
        mtime=$(stat -c'%Y-%m-%d %H:%M:%S' "$file" 2>/dev/null || echo "unknown")
        tokens=$(estimate_tokens_for_file "$file")
        rel_path="${file#${INPUT_DIR}/}"
        ((total_tokens += tokens))

        printf "  %5d | %10s | %8s | %-19s | %s\n" \
            "$i" \
            "$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")" \
            "$(format_tokens $tokens)" \
            "$mtime" \
            "$rel_path"
    done

    printf "  %s\n" "------+------------+----------+---------------------+------------------------------------------"
    printf "  ${BOLD}Total: %d files, ~%s tokens${NC}\n\n" "$i" "$(format_tokens $total_tokens)"
}

#-------------------------------------------------------------------------------
# COMMAND: DRY RUN
#-------------------------------------------------------------------------------
cmd_dry_run() {
    local -a files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done

    (( ${#files[@]} == 0 )) && { info "No files matched criteria"; return; }

    echo ""
    info "${BOLD}DRY RUN${NC} — files that would be included:"
    echo ""

    local total_tokens=0
    for file in "${files[@]}"; do
        local tokens size mtime rel_path
        tokens=$(estimate_tokens_for_file "$file")
        size=$(stat -c%s "$file" 2>/dev/null || echo "0")
        mtime=$(stat -c'%Y-%m-%d %H:%M:%S' "$file" 2>/dev/null || echo "unknown")
        rel_path="${file#${INPUT_DIR}/}"

        # Show truncation indicator
        local trunc=""
        if (( MAX_FILE_TOKENS > 0 && tokens > MAX_FILE_TOKENS )); then
            trunc=" ${Y}[would truncate: ${tokens}→${MAX_FILE_TOKENS}]${NC}"
            tokens=$MAX_FILE_TOKENS
        fi

        ((total_tokens += tokens))
        printf "  %8s  %6s tok  %s  %s%s\n" \
            "$(numfmt --to=iec "$size" 2>/dev/null)" \
            "$(format_tokens $tokens)" \
            "$mtime" \
            "$rel_path" \
            "$trunc"
    done

    echo ""
    info "Total: ${#files[@]} files, ~${total_tokens} tokens"

    if (( SPLIT_TOKENS > 0 )); then
        local parts=$(( (total_tokens + SPLIT_TOKENS - 1) / SPLIT_TOKENS ))
        info "Would create ~$parts output parts (~$(format_tokens $SPLIT_TOKENS) tokens each)"
    fi

    if (( MAX_TOKENS > 0 && total_tokens > MAX_TOKENS )); then
        warn "Selected files ($total_tokens tokens) exceed budget ($MAX_TOKENS tokens)"
    fi
}

#-------------------------------------------------------------------------------
# BANNER
#-------------------------------------------------------------------------------
show_banner() {
    local input_name="${INPUT_DIR##*/}"

    echo "" >&2
    echo "  ${BOLD}${PROG} v${VERSION}${NC} — File Content Aggregator" >&2
    echo "  --------------------------------------------------" >&2
    echo "  Source:  ${INPUT_DIR}" >&2
    [[ -n "$OUTPUT_FILE" ]] && echo "  Output:  ${OUTPUT_FILE}" >&2
    echo "  Format:  ${OUTPUT_FORMAT}" >&2
    [[ -n "$INCLUDE_EXTS" ]] && echo "  Include: ${INCLUDE_EXTS}" >&2
    [[ -n "$EXCLUDE_EXTS" ]] && echo "  Exclude: ${EXCLUDE_EXTS}" >&2
    (( RECENT_COUNT > 0 )) && echo "  Recent:  top ${RECENT_COUNT} files" >&2
    (( MAX_TOKENS > 0 )) && echo "  Budget:  $(format_tokens $MAX_TOKENS) tokens (overflow: ${OVERFLOW})" >&2
    (( MAX_FILE_TOKENS > 0 )) && echo "  Per-file: max $(format_tokens $MAX_FILE_TOKENS) tokens" >&2
    (( SPLIT_TOKENS > 0 )) && echo "  Split:   ~$(format_tokens $SPLIT_TOKENS) tokens per part" >&2
    echo "  Safety:  read-only (source files never modified)" >&2
    echo "" >&2
}

#-------------------------------------------------------------------------------
# RESULTS SUMMARY
#-------------------------------------------------------------------------------
show_results() {
    local elapsed=$(( $(date +%s) - START_TIME ))

    echo "" >&2
    info "Done in ${elapsed}s"
    [[ -n "$OUTPUT_FILE" ]] && info "Output:   ${OUTPUT_FILE}"
    (( STAT_BYTES > 0 )) && info "Size:     $(numfmt --to=iec $STAT_BYTES 2>/dev/null || echo "${STAT_BYTES} bytes")"
    (( STAT_TOKENS > 0 )) && info "Tokens:   ~${STAT_TOKENS}"
    info "Files:    ${STAT_FILES}"
    (( STAT_SKIPPED > 0 )) && info "Skipped:  ${STAT_SKIPPED}"
    echo "" >&2
}

#-------------------------------------------------------------------------------
# HELP
#-------------------------------------------------------------------------------
show_help() {
    cat << 'HELPEOF'

  fagg v4.0.0 — File Content Aggregator
  ======================================

  Recursively scan directories and aggregate file contents into a single
  output file (or multiple parts). Perfect for LLM context, code reviews,
  or documentation. READ-ONLY: never modifies source files.

USAGE:
    fagg <input_dir> <output_file> [OPTIONS]
    fagg <input_dir> --list [OPTIONS]
    fagg --help | --version

FILTERING:
    -i, --include <exts>        Only these extensions    (e.g., "ts,tsx,json")
    -e, --exclude <exts>        Skip these extensions    (e.g., "log,tmp")
    -d, --exclude-dirs <dirs>   Skip these directories   (e.g., "tests,fixtures")
    -s, --max-size <size>       Max source file size     (default: 10M)
    --since <date>              Files modified after date (e.g., "2025-01-01")

TOKEN CONTROLS:
    --max-tokens <n>            Total token budget. Picks latest files until
                                budget is approximately filled. Files are kept
                                whole unless they exceed overflow tolerance.
                                (e.g., --max-tokens 50000)

    --max-file-tokens <n>       Per-source-file token cap. Files exceeding this
                                are truncated with a marker.
                                (e.g., --max-file-tokens 5000)

    --split-tokens <n>          Split output into multiple files, each containing
                                approximately <n> tokens.
                                (e.g., --split-tokens 50000)

    --overflow <n>              Tolerance above budget before skipping a file.
                                Default: 3000 tokens.

    -r, --recent <n>            Consider only N most recently modified files
                                BEFORE applying token budget.

OUTPUT:
    -f, --format <fmt>          text (default), markdown, json
    -n, --line-numbers          Add line numbers to content
    --stats                     Show extension breakdown after processing

MODES:
    --list                      List matching files with metadata (no output file)
    --dry-run                   Preview what would be processed
    --verbose                   Debug logging

EXAMPLES:

    # Fill ~50k tokens with the latest code
    fagg ./src out.txt -i "ts,tsx" --max-tokens 50000

    # Same but limit each source file to 5k tokens
    fagg ./src out.txt -i "ts,tsx" --max-tokens 50000 --max-file-tokens 5000

    # Multi-part: 50k tokens per part, 700k total, files capped at 5k
    fagg ./src out.txt -i "py" --split-tokens 50000 --max-tokens 700000 --max-file-tokens 5000

    # Recent 20 files within 40k token budget
    fagg ./src out.txt -r 20 --max-tokens 40000

    # List files with token estimates
    fagg ./src --list -i "ts,tsx,json"

    # Dry run to preview
    fagg ./src out.txt --dry-run --max-tokens 50000

TOKEN BUDGET LOGIC:
    Files are sorted newest-first, then selected one by one:
    1. If file fits within remaining budget  -> INCLUDE
    2. If file exceeds budget by <= overflow -> INCLUDE (slight overshoot OK)
    3. If file exceeds budget by > overflow  -> SKIP (but keep checking smaller files)
    This ensures output stays close to the budget while keeping files whole.

HELPEOF
}

show_version() {
    echo "$PROG v$VERSION (released $RELEASE)"
    echo "Safety: read-only on source files"
}

#-------------------------------------------------------------------------------
# ARGUMENT PARSING
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)       show_help; exit 0 ;;
            -v|--version)    show_version; exit 0 ;;
            -i|--include)    INCLUDE_EXTS="$2"; shift 2 ;;
            -e|--exclude)    EXCLUDE_EXTS="$2"; shift 2 ;;
            -d|--exclude-dirs) EXCLUDE_DIRS="$2"; shift 2 ;;
            -s|--max-size)   MAX_FILE_SIZE="$2"; shift 2 ;;
            -r|--recent)     RECENT_COUNT="$2"; shift 2 ;;
            -f|--format)     OUTPUT_FORMAT="$2"; shift 2 ;;
            -n|--line-numbers) LINE_NUMBERS=true; shift ;;
            --max-tokens)    MAX_TOKENS="$2"; shift 2 ;;
            --max-file-tokens) MAX_FILE_TOKENS="$2"; shift 2 ;;
            --split-tokens)  SPLIT_TOKENS="$2"; shift 2 ;;
            --overflow)      OVERFLOW="$2"; shift 2 ;;
            --since)         SINCE_DATE="$2"; shift 2 ;;
            --list)          LIST_ONLY=true; shift ;;
            --dry-run)       DRY_RUN=true; shift ;;
            --verbose)       VERBOSE=true; shift ;;
            --stats)         SHOW_STATS=true; shift ;;
            --)              shift; break ;;
            -*)              err "Unknown option: $1 (use --help)" ;;
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

    parse_args "$@"
    validate
    show_banner

    # 1. Collect matching files (sorted newest first)
    info "Collecting files..."
    local -a all_files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && all_files+=("$f")
    done < <(collect_files "$INPUT_DIR")

    local total_found=${#all_files[@]}
    (( total_found == 0 )) && err "No files matched criteria"
    info "Found $total_found files"

    # 2. Apply token budget selection if specified
    local -a selected_files=()
    if (( MAX_TOKENS > 0 )); then
        while IFS= read -r f; do
            [[ -n "$f" ]] && selected_files+=("$f")
        done < <(select_within_budget "$MAX_TOKENS" "${all_files[@]}")
    else
        selected_files=("${all_files[@]}")
    fi

    # 3. Route to appropriate command
    if [[ "$LIST_ONLY" == "true" ]]; then
        printf '%s\n' "${selected_files[@]}" | cmd_list
    elif [[ "$DRY_RUN" == "true" ]]; then
        printf '%s\n' "${selected_files[@]}" | cmd_dry_run
    elif (( SPLIT_TOKENS > 0 )); then
        printf '%s\n' "${selected_files[@]}" | cmd_split_output
        show_results
    else
        printf '%s\n' "${selected_files[@]}" | cmd_single_output
        show_results
    fi

    # 4. Optional stats
    if [[ "$SHOW_STATS" == "true" ]]; then
        echo "" >&2
        info "Extension breakdown:"
        printf '%s\n' "${selected_files[@]}" | \
            grep -oE '\.[^./]+$' | tr '[:upper:]' '[:lower:]' | \
            sort | uniq -c | sort -rn | \
            while read -r count ext; do
                printf "  %5d  %s\n" "$count" "$ext"
            done >&2
    fi
}

main "$@"