#!/usr/bin/env bash

# =============================================================================
#
#   ███████╗ █████╗  ██████╗  ██████╗
#   ██╔════╝██╔══██╗██╔════╝ ██╔════╝
#   █████╗  ███████║██║  ███╗██║  ███╗
#   ██╔══╝  ██╔══██║██║   ██║██║   ██║
#   ██║     ██║  ██║╚██████╔╝╚██████╔╝
#   ╚═╝     ╚═╝  ╚═╝ ╚═════╝  ╚═════╝
#
#   File Content Aggregator (fagg) v3.1.0
#
# =============================================================================
#
#   Author:       Maher
#   Version:      3.1.0
#   License:      MIT
#
#   SAFETY: READ-ONLY on source files. Will NEVER delete, modify, move,
#           or copy any source files. Only creates the output file.
#
#   USE CASES:
#     - Feeding project context to LLMs (ChatGPT, Claude, etc.)
#     - Code review preparation
#     - Project documentation snapshots
#     - Onboarding new developers
#
#   DEPENDENCIES:
#     Required: bash 4+, find, sort, wc, file, date, bc
#     Optional: tree (--tree), git (--gitignore), fzf (--interactive)
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────

readonly PROG_NAME="fagg"
readonly PROG_FULL_NAME="File Content Aggregator"
readonly PROG_VERSION="3.1.0"
readonly PROG_AUTHOR="Maher"
readonly PROG_LICENSE="MIT"

# ─────────────────────────────────────────────────────────────────────────────
# GLOBAL CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

INPUT_DIR=""
OUTPUT_FILE=""
INCLUDE_EXTS=()
EXCLUDE_EXTS=()
EXCLUDE_DIRS=()
EXCLUDE_PATTERNS=()
MAX_FILE_SIZE="1M"
TOP_N_RECENT=0
SHOW_TREE=false
SHOW_STATS=false
LINE_NUMBERS=false
RESPECT_GITIGNORE=false
DRY_RUN=false
SILENT=false
USE_DEFAULT_EXCLUDES=true
LIST_FILES_ONLY=false
OUTPUT_FORMAT="text"
SHOW_METADATA=false
SEARCH_PATTERN=""
COPY_TO_CLIPBOARD=false
SHOW_TOC=false
CONFIG_FILE=""
SINCE_DATE=""
SPLIT_COUNT=0
HEADER_ONLY=0
EXCLUDE_EMPTY=false
ESTIMATE_TOKENS=false
INTERACTIVE=false
DEBUG_MODE=false
MAX_TOKENS=0           # 0 = unlimited. Stop aggregating after N tokens total
MAX_FILE_TOKENS=0      # 0 = unlimited. Skip individual files exceeding N tokens

# ─────────────────────────────────────────────────────────────────────────────
# DEFAULT EXCLUSIONS
# ─────────────────────────────────────────────────────────────────────────────

readonly DEFAULT_EXCLUDE_EXTS=(
    "png" "jpg" "jpeg" "gif" "bmp" "svg" "ico" "webp" "tiff" "tif" "raw"
    "mp3" "mp4" "avi" "mov" "mkv" "flv" "wmv" "wav" "ogg" "webm" "m4a" "flac"
    "zip" "tar" "gz" "bz2" "xz" "rar" "7z" "zst" "tgz"
    "pdf" "doc" "docx" "xls" "xlsx" "ppt" "pptx" "odt" "ods"
    "exe" "dll" "so" "dylib" "bin" "o" "a" "class" "pyc" "pyo" "wasm"
    "woff" "woff2" "ttf" "eot" "otf"
    "db" "sqlite" "sqlite3" "mdb"
    "DS_Store" "lock" "swp" "swo" "bak" "orig" "map"
)

readonly DEFAULT_EXCLUDE_DIRS=(
    "node_modules" ".git" "__pycache__" ".next" ".nuxt"
    "dist" "build" ".venv" "venv" "env"
    ".idea" ".vscode" "vendor" ".terraform"
    "coverage" ".cache" "tmp" ".tox" "eggs"
    ".svn" ".hg" ".sass-cache" "bower_components"
    ".parcel-cache" ".turbo" ".output" "target"
    ".gradle" ".mvn" ".cargo"
)

# ─────────────────────────────────────────────────────────────────────────────
# COLORS — using $'...' so escape bytes are REAL, not literal strings
# This fixes --help and --version showing raw \033 codes
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 2 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_BLUE=$'\033[0;34m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_BOLD=$'\033[1m'
    readonly C_DIM=$'\033[2m'
    readonly C_NC=$'\033[0m'
else
    readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    readonly C_BOLD='' C_DIM='' C_NC=''
fi

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING — uses if/then to avoid set -e failures
# ─────────────────────────────────────────────────────────────────────────────

log_info() {
    if [[ "$SILENT" == false ]]; then
        echo "${C_GREEN}[INFO]${C_NC}  $*" >&2
    fi
    return 0
}

log_warn() {
    if [[ "$SILENT" == false ]]; then
        echo "${C_YELLOW}[WARN]${C_NC}  $*" >&2
    fi
    return 0
}

log_error() {
    echo "${C_RED}[ERROR]${C_NC} $*" >&2
    return 0
}

log_debug() {
    if [[ "$SILENT" == false && "$DEBUG_MODE" == true ]]; then
        echo "${C_DIM}[DEBUG]${C_NC} $*" >&2
    fi
    return 0
}

log_step() {
    if [[ "$SILENT" == false ]]; then
        echo "${C_CYAN}>${C_NC} $*" >&2
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SAFETY — ensure we NEVER write inside source directory
# ─────────────────────────────────────────────────────────────────────────────

safety_check() {
    local target="$1"
    local resolved_target resolved_input
    resolved_target=$(readlink -f "$target" 2>/dev/null || echo "$target")
    resolved_input=$(readlink -f "$INPUT_DIR" 2>/dev/null || echo "$INPUT_DIR")

    if [[ "$resolved_target" == "$resolved_input"/* ]]; then
        log_error "SAFETY VIOLATION: Cannot write inside the source directory!"
        log_error "  Target: $resolved_target"
        log_error "  Source: $resolved_input"
        log_error "  Output file must be OUTSIDE the scanned directory."
        exit 99
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# UTILITY FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

## Join array elements with a delimiter (fixes IFS issue)
join_arr() {
    local delim="$1"; shift
    local result=""
    local first=true
    for item in "$@"; do
        if [[ "$first" == true ]]; then
            result="$item"
            first=false
        else
            result="${result}${delim}${item}"
        fi
    done
    echo "$result"
}

## ASCII separator line (fixes garbled multi-byte tr issue)
separator() {
    local char="${1:--}"
    local len="${2:-80}"
    local i
    local out=""
    for ((i = 0; i < len; i++)); do
        out="${out}${char}"
    done
    echo "$out"
}

## Convert human-readable size to bytes
size_to_bytes() {
    local size="$1"
    local number unit
    number=$(echo "$size" | sed 's/[^0-9.]//g')
    unit=$(echo "$size" | sed 's/[0-9.]//g' | tr '[:lower:]' '[:upper:]')
    case "$unit" in
        K|KB) echo "$number * 1024" | bc | cut -d. -f1 ;;
        M|MB) echo "$number * 1024 * 1024" | bc | cut -d. -f1 ;;
        G|GB) echo "$number * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
        *)    echo "$number" | cut -d. -f1 ;;
    esac
}

## Convert bytes to human readable
bytes_to_human() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    elif (( bytes >= 1048576 )); then
        echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
    elif (( bytes >= 1024 )); then
        echo "$(echo "scale=2; $bytes / 1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}

## Estimate token count (~4 chars per token)
estimate_tokens() {
    local char_count="$1"
    echo $(( (char_count + 3) / 4 ))
}

## Get lowercase file extension
get_extension() {
    local filename
    filename=$(basename "$1")
    if [[ "$filename" == .* && "${filename#.}" != *.* ]]; then
        echo "${filename:1}" | tr '[:upper:]' '[:lower:]'
    elif [[ "$filename" == *.* ]]; then
        echo "${filename##*.}" | tr '[:upper:]' '[:lower:]'
    else
        echo ""
    fi
}

## Check if value is in array
in_array() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

## Detect binary file
is_binary() {
    if command -v file &>/dev/null; then
        local mime
        mime=$(file --mime-encoding "$1" 2>/dev/null || echo "")
        if echo "$mime" | grep -q "binary"; then
            return 0
        fi
    fi
    return 1
}

## Check gitignore
is_gitignored() {
    if [[ "$RESPECT_GITIGNORE" == true ]] && command -v git &>/dev/null; then
        if git -C "$INPUT_DIR" check-ignore -q "$1" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

## File modification time (display)
get_mtime_display() {
    stat -c '%y' "$1" 2>/dev/null | cut -d. -f1 || \
    stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1" 2>/dev/null || \
    echo "unknown"
}

## File modification time (epoch)
get_mtime_epoch() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

## File permissions
get_permissions() {
    stat -c '%A' "$1" 2>/dev/null || stat -f '%Sp' "$1" 2>/dev/null || echo "unknown"
}

## Escape for JSON
json_escape() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\"/\\\"}"
    text="${text//$'\n'/\\n}"
    text="${text//$'\t'/\\t}"
    text="${text//$'\r'/\\r}"
    echo "$text"
}

## Map extension to markdown language
ext_to_lang() {
    case "$1" in
        py)      echo "python" ;;
        js)      echo "javascript" ;;
        ts)      echo "typescript" ;;
        tsx)     echo "tsx" ;;
        jsx)     echo "jsx" ;;
        sh|bash) echo "bash" ;;
        yml)     echo "yaml" ;;
        md)      echo "markdown" ;;
        rb)      echo "ruby" ;;
        rs)      echo "rust" ;;
        go)      echo "go" ;;
        kt)      echo "kotlin" ;;
        cs)      echo "csharp" ;;
        cpp|cc)  echo "cpp" ;;
        c)       echo "c" ;;
        java)    echo "java" ;;
        sql)     echo "sql" ;;
        html)    echo "html" ;;
        css)     echo "css" ;;
        scss)    echo "scss" ;;
        xml)     echo "xml" ;;
        toml)    echo "toml" ;;
        ini|cfg) echo "ini" ;;
        *)       echo "$1" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# HELP & VERSION
# ─────────────────────────────────────────────────────────────────────────────

show_version() {
    cat >&2 <<EOF
${C_BOLD}${PROG_FULL_NAME}${C_NC} (${PROG_NAME}) v${C_GREEN}${PROG_VERSION}${C_NC}

  Author:   ${PROG_AUTHOR}
  License:  ${PROG_LICENSE}

  SAFETY: READ-ONLY on source files. Will never modify your project.
  The only write operation is creating the output file.
EOF
    exit 0
}

show_help() {
    cat >&2 <<EOF
${C_BOLD}${C_BLUE}$(separator '=' 78)${C_NC}
${C_BOLD}  ${PROG_FULL_NAME} v${PROG_VERSION}${C_NC}
${C_BOLD}${C_BLUE}$(separator '=' 78)${C_NC}

  Recursively scan directories and aggregate file contents into a single file.
  Perfect for feeding project context to LLMs, code reviews, or documentation.

  ${C_BOLD}${C_RED}SAFETY: READ-ONLY on source files. Will never modify your project.${C_NC}

${C_BOLD}${C_YELLOW}USAGE:${C_NC}
    ${PROG_NAME} <input_dir> <output_file> [OPTIONS]
    ${PROG_NAME} <input_dir> --list [OPTIONS]
    ${PROG_NAME} --help | --version

${C_BOLD}${C_YELLOW}POSITIONAL ARGUMENTS:${C_NC}
    ${C_GREEN}<input_dir>${C_NC}          Directory to scan (read-only)
    ${C_GREEN}<output_file>${C_NC}        Output file path (created if needed)

${C_BOLD}${C_YELLOW}FILTERING OPTIONS:${C_NC}
    ${C_GREEN}-i, --include <exts>${C_NC}     Whitelist extensions (comma-separated)
                              Example: -i "py,tsx,json,ts,css"

    ${C_GREEN}-e, --exclude <exts>${C_NC}     Blacklist extensions (comma-separated)
                              Example: -e "log,tmp,bak"

    ${C_GREEN}-d, --exclude-dirs <d>${C_NC}   Exclude directories (comma-separated)
                              Example: -d "generated,temp,logs"

    ${C_GREEN}-p, --exclude-pattern <p>${C_NC}
                              Exclude filenames matching glob (comma-separated)
                              Example: -p "*.test.*,*.spec.*,*.min.*"

    ${C_GREEN}-s, --max-size <size>${C_NC}    Max file size (default: 1M)
                              Supports: B, K, M, G  Example: -s 500K

    ${C_GREEN}--no-default-excludes${C_NC}    Disable all default exclusions
    ${C_GREEN}--gitignore${C_NC}              Respect .gitignore rules (requires git)
    ${C_GREEN}--exclude-empty${C_NC}          Skip files with zero content lines

${C_BOLD}${C_YELLOW}TIME-BASED OPTIONS:${C_NC}
    ${C_GREEN}-r, --recent <N>${C_NC}         Top N most recently modified files
                              Example: -r 20

    ${C_GREEN}--since <date>${C_NC}            Files modified after this date
                              Example: --since "2025-01-01"
                              Example: --since "3 days ago"

${C_BOLD}${C_YELLOW}CONTENT SEARCH:${C_NC}
    ${C_GREEN}-g, --grep <pattern>${C_NC}     Only include files matching content pattern
                              Example: -g "TODO|FIXME|HACK"

${C_BOLD}${C_YELLOW}TOKEN CONTROL (for LLM context limits):${C_NC}
    ${C_GREEN}--tokens${C_NC}                 Show estimated token count per file and total
                              Uses ~4 chars/token approximation

    ${C_GREEN}--max-tokens <N>${C_NC}         Stop aggregating after N total tokens
                              Files are added until budget is exhausted
                              Example: --max-tokens 50000

    ${C_GREEN}--max-file-tokens <N>${C_NC}    Skip individual files exceeding N tokens
                              Example: --max-file-tokens 10000

    ${C_GREEN}--split <N>${C_NC}              Split output: N files per chunk
                              Creates: output_part1.txt, output_part2.txt, ...
                              Example: --split 10
                              Note: 114 files with --split 5 = 23 part files

${C_BOLD}${C_YELLOW}OUTPUT OPTIONS:${C_NC}
    ${C_GREEN}-f, --format <fmt>${C_NC}       Output format: text | markdown | json

    ${C_GREEN}-n, --line-numbers${C_NC}       Add line numbers to file contents
    ${C_GREEN}-m, --metadata${C_NC}           Show size, date, permissions per file
    ${C_GREEN}-t, --tree${C_NC}               Directory tree at top of output
    ${C_GREEN}--toc${C_NC}                    Table of contents listing all files
    ${C_GREEN}--stats${C_NC}                  Statistics summary at end
    ${C_GREEN}--header-only <N>${C_NC}        Only first N lines per file
    ${C_GREEN}--clipboard${C_NC}              Copy output to clipboard after writing

${C_BOLD}${C_YELLOW}LISTING & PREVIEW:${C_NC}
    ${C_GREEN}-l, --list${C_NC}              List all matching files (no output file needed)
    ${C_GREEN}--dry-run${C_NC}               Preview files with sizes and dates
    ${C_GREEN}--interactive${C_NC}            Select files interactively (requires fzf)

${C_BOLD}${C_YELLOW}CONFIGURATION:${C_NC}
    ${C_GREEN}-c, --config <file>${C_NC}     Load options from config file
    ${C_GREEN}--silent${C_NC}                Suppress info messages
    ${C_GREEN}--debug${C_NC}                 Verbose debug logging
    ${C_GREEN}-h, --help${C_NC}              Show this help
    ${C_GREEN}-v, --version${C_NC}           Show version

${C_BOLD}${C_YELLOW}EXAMPLES:${C_NC}

    # Basic usage
    ${PROG_NAME} ./my-project output.txt

    # Only TypeScript files
    ${PROG_NAME} ./frontend output.txt -i "tsx,ts,json,css"

    # Top 15 recently modified, with token estimate
    ${PROG_NAME} ./backend output.txt -i "py" -r 15 --tokens --stats

    # Stay within 50K token budget
    ${PROG_NAME} ./project output.txt -i "py,ts" --max-tokens 50000

    # Skip files bigger than 10K tokens
    ${PROG_NAME} ./project output.txt --max-file-tokens 10000

    # Files changed in the last 2 days
    ${PROG_NAME} ./project output.txt --since "2 days ago"

    # Markdown for AI context
    ${PROG_NAME} ./src context.md -f markdown -t --toc --stats --tokens

    # Split into 10-file chunks
    ${PROG_NAME} ./project output.txt --split 10

    # Preview first 30 lines of each file
    ${PROG_NAME} ./project output.txt --header-only 30

    # Find files containing TODO
    ${PROG_NAME} ./src output.txt -g "TODO|FIXME" -i "py,js"

    # List all Python files
    ${PROG_NAME} ./project --list -i "py"

    # Dry run
    ${PROG_NAME} ./project output.txt --dry-run

${C_BOLD}${C_YELLOW}CONFIG FILE FORMAT (.faggrc):${C_NC}

    # .faggrc
    include=py,ts,tsx,json,yaml,md
    exclude-dirs=tests,fixtures
    max-size=2M
    format=markdown
    line-numbers=true
    tree=true
    stats=true
    max-tokens=100000

${C_BOLD}${C_YELLOW}EXIT CODES:${C_NC}
    0   Success
    1   Invalid arguments
    2   Input directory not found
    3   No files matched criteria
    99  Safety violation

${C_BOLD}${C_BLUE}$(separator '=' 78)${C_NC}
EOF
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG FILE LOADER
# ─────────────────────────────────────────────────────────────────────────────

load_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    log_info "Loading config: ${C_CYAN}${config_file}${C_NC}"

    while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs 2>/dev/null || echo "")
        [[ -z "$key" || "$key" == \#* ]] && continue
        value=$(echo "$value" | xargs 2>/dev/null || echo "")

        case "$key" in
            include)
                IFS=',' read -ra INCLUDE_EXTS <<< "$value"
                local idx
                for idx in "${!INCLUDE_EXTS[@]}"; do
                    INCLUDE_EXTS[$idx]=$(echo "${INCLUDE_EXTS[$idx]}" | sed 's/^\.//' | tr '[:upper:]' '[:lower:]' | xargs)
                done ;;
            exclude)
                IFS=',' read -ra EXCLUDE_EXTS <<< "$value"
                local idx
                for idx in "${!EXCLUDE_EXTS[@]}"; do
                    EXCLUDE_EXTS[$idx]=$(echo "${EXCLUDE_EXTS[$idx]}" | sed 's/^\.//' | tr '[:upper:]' '[:lower:]' | xargs)
                done ;;
            exclude-dirs)
                IFS=',' read -ra EXCLUDE_DIRS <<< "$value"
                local idx
                for idx in "${!EXCLUDE_DIRS[@]}"; do
                    EXCLUDE_DIRS[$idx]=$(echo "${EXCLUDE_DIRS[$idx]}" | xargs)
                done ;;
            exclude-pattern)    IFS=',' read -ra EXCLUDE_PATTERNS <<< "$value" ;;
            max-size)           MAX_FILE_SIZE="$value" ;;
            format)             OUTPUT_FORMAT="$value" ;;
            line-numbers)       [[ "$value" == "true" ]] && LINE_NUMBERS=true ;;
            tree)               [[ "$value" == "true" ]] && SHOW_TREE=true ;;
            toc)                [[ "$value" == "true" ]] && SHOW_TOC=true ;;
            stats)              [[ "$value" == "true" ]] && SHOW_STATS=true ;;
            metadata)           [[ "$value" == "true" ]] && SHOW_METADATA=true ;;
            gitignore)          [[ "$value" == "true" ]] && RESPECT_GITIGNORE=true ;;
            tokens)             [[ "$value" == "true" ]] && ESTIMATE_TOKENS=true ;;
            exclude-empty)      [[ "$value" == "true" ]] && EXCLUDE_EMPTY=true ;;
            recent)             TOP_N_RECENT="$value" ;;
            since)              SINCE_DATE="$value" ;;
            grep)               SEARCH_PATTERN="$value" ;;
            split)              SPLIT_COUNT="$value" ;;
            header-only)        HEADER_ONLY="$value" ;;
            max-tokens)         MAX_TOKENS="$value" ;;
            max-file-tokens)    MAX_FILE_TOKENS="$value" ;;
            *)                  log_warn "Unknown config key: $key" ;;
        esac
    done < "$config_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# ARGUMENT PARSER
# ─────────────────────────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)              show_help ;;
            -v|--version)           show_version ;;

            -i|--include)
                IFS=',' read -ra INCLUDE_EXTS <<< "$2"
                local idx
                for idx in "${!INCLUDE_EXTS[@]}"; do
                    INCLUDE_EXTS[$idx]=$(echo "${INCLUDE_EXTS[$idx]}" | sed 's/^\.//' | tr '[:upper:]' '[:lower:]' | xargs)
                done
                shift 2 ;;
            -e|--exclude)
                IFS=',' read -ra EXCLUDE_EXTS <<< "$2"
                local idx
                for idx in "${!EXCLUDE_EXTS[@]}"; do
                    EXCLUDE_EXTS[$idx]=$(echo "${EXCLUDE_EXTS[$idx]}" | sed 's/^\.//' | tr '[:upper:]' '[:lower:]' | xargs)
                done
                shift 2 ;;
            -d|--exclude-dirs)
                IFS=',' read -ra EXCLUDE_DIRS <<< "$2"
                local idx
                for idx in "${!EXCLUDE_DIRS[@]}"; do
                    EXCLUDE_DIRS[$idx]=$(echo "${EXCLUDE_DIRS[$idx]}" | xargs)
                done
                shift 2 ;;
            -p|--exclude-pattern)   IFS=',' read -ra EXCLUDE_PATTERNS <<< "$2"; shift 2 ;;
            -s|--max-size)          MAX_FILE_SIZE="$2"; shift 2 ;;
            --no-default-excludes)  USE_DEFAULT_EXCLUDES=false; shift ;;
            --gitignore)            RESPECT_GITIGNORE=true; shift ;;
            --exclude-empty)        EXCLUDE_EMPTY=true; shift ;;

            -r|--recent)            TOP_N_RECENT="$2"; shift 2 ;;
            --since)                SINCE_DATE="$2"; shift 2 ;;

            -g|--grep)              SEARCH_PATTERN="$2"; shift 2 ;;

            -f|--format)            OUTPUT_FORMAT="$2"; shift 2 ;;
            -n|--line-numbers)      LINE_NUMBERS=true; shift ;;
            -m|--metadata)          SHOW_METADATA=true; shift ;;
            -t|--tree)              SHOW_TREE=true; shift ;;
            --toc)                  SHOW_TOC=true; shift ;;
            --stats)                SHOW_STATS=true; shift ;;
            --header-only)          HEADER_ONLY="$2"; shift 2 ;;
            --clipboard)            COPY_TO_CLIPBOARD=true; shift ;;
            --split)                SPLIT_COUNT="$2"; shift 2 ;;
            --tokens)               ESTIMATE_TOKENS=true; shift ;;
            --max-tokens)           MAX_TOKENS="$2"; shift 2 ;;
            --max-file-tokens)      MAX_FILE_TOKENS="$2"; shift 2 ;;

            -l|--list)              LIST_FILES_ONLY=true; shift ;;
            --dry-run)              DRY_RUN=true; shift ;;
            --interactive)          INTERACTIVE=true; shift ;;

            -c|--config)            CONFIG_FILE="$2"; shift 2 ;;
            --silent)               SILENT=true; shift ;;
            --debug)                DEBUG_MODE=true; shift ;;

            -*)
                log_error "Unknown option: ${C_BOLD}$1${C_NC}"
                echo "  Run ${C_GREEN}${PROG_NAME} --help${C_NC} for usage." >&2
                exit 1 ;;
            *)
                if [[ -z "$INPUT_DIR" ]]; then
                    INPUT_DIR="$1"
                elif [[ -z "$OUTPUT_FILE" ]]; then
                    OUTPUT_FILE="$1"
                else
                    log_error "Unexpected argument: ${C_BOLD}$1${C_NC}"
                    echo "  Run ${C_GREEN}${PROG_NAME} --help${C_NC} for usage." >&2
                    exit 1
                fi
                shift ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

validate() {
    if [[ -n "$CONFIG_FILE" ]]; then
        load_config "$CONFIG_FILE"
    fi

    if [[ -z "$INPUT_DIR" ]]; then
        log_error "Input directory is required."
        echo "  Usage: ${PROG_NAME} <input_dir> <output_file> [options]" >&2
        exit 1
    fi

    if [[ "$LIST_FILES_ONLY" == false && -z "$OUTPUT_FILE" ]]; then
        log_error "Output file is required (unless using --list)."
        echo "  Usage: ${PROG_NAME} <input_dir> <output_file> [options]" >&2
        exit 1
    fi

    if [[ ! -d "$INPUT_DIR" ]]; then
        log_error "Directory does not exist: $INPUT_DIR"
        exit 2
    fi

    INPUT_DIR=$(cd "$INPUT_DIR" && pwd)

    if [[ -n "$OUTPUT_FILE" ]]; then
        local output_dir
        output_dir=$(dirname "$OUTPUT_FILE")
        if [[ "$output_dir" != "." && ! -d "$output_dir" ]]; then
            mkdir -p "$output_dir"
            log_info "Created output directory: ${C_CYAN}${output_dir}${C_NC}"
        fi
        if [[ -d "$output_dir" ]]; then
            OUTPUT_FILE="$(cd "$output_dir" && pwd)/$(basename "$OUTPUT_FILE")"
        fi
        safety_check "$OUTPUT_FILE"
    fi

    case "$OUTPUT_FORMAT" in
        text|markdown|json) ;;
        *) log_error "Invalid format: $OUTPUT_FORMAT. Use: text, markdown, json"; exit 1 ;;
    esac

    if [[ "$TOP_N_RECENT" != "0" ]]; then
        if ! [[ "$TOP_N_RECENT" =~ ^[0-9]+$ ]]; then
            log_error "--recent must be a positive integer"; exit 1
        fi
    fi

    if [[ "$SPLIT_COUNT" != "0" ]]; then
        if ! [[ "$SPLIT_COUNT" =~ ^[0-9]+$ ]] || [[ "$SPLIT_COUNT" -lt 1 ]]; then
            log_error "--split must be a positive integer"; exit 1
        fi
    fi

    if [[ "$HEADER_ONLY" != "0" ]]; then
        if ! [[ "$HEADER_ONLY" =~ ^[0-9]+$ ]]; then
            log_error "--header-only must be a positive integer"; exit 1
        fi
    fi

    if [[ "$MAX_TOKENS" != "0" ]]; then
        if ! [[ "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
            log_error "--max-tokens must be a positive integer"; exit 1
        fi
        ESTIMATE_TOKENS=true
    fi

    if [[ "$MAX_FILE_TOKENS" != "0" ]]; then
        if ! [[ "$MAX_FILE_TOKENS" =~ ^[0-9]+$ ]]; then
            log_error "--max-file-tokens must be a positive integer"; exit 1
        fi
        ESTIMATE_TOKENS=true
    fi

    if [[ -n "$SINCE_DATE" ]]; then
        if ! date -d "$SINCE_DATE" &>/dev/null 2>&1; then
            log_error "Invalid date: $SINCE_DATE"
            exit 1
        fi
    fi

    if [[ "$INTERACTIVE" == true ]]; then
        if ! command -v fzf &>/dev/null; then
            log_error "--interactive requires fzf. Install: sudo apt install fzf"
            exit 1
        fi
    fi

    # Merge defaults
    if [[ "$USE_DEFAULT_EXCLUDES" == true ]]; then
        if [[ ${#INCLUDE_EXTS[@]} -eq 0 ]]; then
            EXCLUDE_EXTS=("${EXCLUDE_EXTS[@]}" "${DEFAULT_EXCLUDE_EXTS[@]}")
        fi
        EXCLUDE_DIRS=("${EXCLUDE_DIRS[@]}" "${DEFAULT_EXCLUDE_DIRS[@]}")
    fi

    # Deduplicate
    if [[ ${#EXCLUDE_EXTS[@]} -gt 0 ]]; then
        local -A seen=(); local unique=()
        for ext in "${EXCLUDE_EXTS[@]}"; do
            if [[ -z "${seen[$ext]+x}" ]]; then seen[$ext]=1; unique+=("$ext"); fi
        done
        EXCLUDE_EXTS=("${unique[@]}")
    fi
    if [[ ${#EXCLUDE_DIRS[@]} -gt 0 ]]; then
        local -A seen2=(); local unique2=()
        for dir in "${EXCLUDE_DIRS[@]}"; do
            if [[ -z "${seen2[$dir]+x}" ]]; then seen2[$dir]=1; unique2+=("$dir"); fi
        done
        EXCLUDE_DIRS=("${unique2[@]}")
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE FILTER ENGINE
# ─────────────────────────────────────────────────────────────────────────────

should_exclude_dir() {
    local base
    base=$(basename "$1")
    if [[ ${#EXCLUDE_DIRS[@]} -gt 0 ]]; then
        for pattern in "${EXCLUDE_DIRS[@]}"; do
            # shellcheck disable=SC2254
            case "$base" in $pattern) return 0 ;; esac
        done
    fi
    return 1
}

should_include_file() {
    local filepath="$1"
    local filename ext
    filename=$(basename "$filepath")
    ext=$(get_extension "$filepath")

    # Skip output file
    if [[ -n "$OUTPUT_FILE" && "$filepath" == "$OUTPUT_FILE" ]]; then return 1; fi

    # Whitelist
    if [[ ${#INCLUDE_EXTS[@]} -gt 0 ]]; then
        if ! in_array "$ext" "${INCLUDE_EXTS[@]}"; then return 1; fi
    fi

    # Blacklist
    if [[ ${#EXCLUDE_EXTS[@]} -gt 0 ]]; then
        if in_array "$ext" "${EXCLUDE_EXTS[@]}"; then return 1; fi
    fi

    # Pattern exclusion
    if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            # shellcheck disable=SC2254
            case "$filename" in $pattern) return 1 ;; esac
        done
    fi

    # Size check
    local max_bytes file_size
    max_bytes=$(size_to_bytes "$MAX_FILE_SIZE")
    file_size=$(wc -c < "$filepath" 2>/dev/null || echo 0)
    if (( file_size > max_bytes )); then return 1; fi

    # Per-file token limit
    if [[ "$MAX_FILE_TOKENS" -gt 0 ]]; then
        local file_tokens
        file_tokens=$(estimate_tokens "$file_size")
        if (( file_tokens > MAX_FILE_TOKENS )); then return 1; fi
    fi

    # Empty check
    if [[ "$EXCLUDE_EMPTY" == true ]]; then
        local lc
        lc=$(wc -l < "$filepath" 2>/dev/null || echo 0)
        if (( lc == 0 )); then return 1; fi
    fi

    # Binary check
    if is_binary "$filepath"; then return 1; fi

    # Gitignore
    if is_gitignored "$filepath"; then return 1; fi

    # Since date
    if [[ -n "$SINCE_DATE" ]]; then
        local since_epoch file_epoch
        since_epoch=$(date -d "$SINCE_DATE" +%s 2>/dev/null || echo 0)
        file_epoch=$(get_mtime_epoch "$filepath")
        if (( file_epoch < since_epoch )); then return 1; fi
    fi

    # Content grep
    if [[ -n "$SEARCH_PATTERN" ]]; then
        if ! grep -qlE "$SEARCH_PATTERN" "$filepath" 2>/dev/null; then return 1; fi
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE COLLECTOR
# ─────────────────────────────────────────────────────────────────────────────

collect_files() {
    local all_files=()

    while IFS= read -r -d '' file; do
        local rel_path="${file#"$INPUT_DIR"/}"
        local skip=false

        # Check directory exclusions
        local old_ifs="$IFS"
        IFS='/'
        local -a path_parts=($rel_path)
        IFS="$old_ifs"

        local idx
        for (( idx=0; idx < ${#path_parts[@]} - 1; idx++ )); do
            if should_exclude_dir "${path_parts[$idx]}"; then
                skip=true
                break
            fi
        done

        if [[ "$skip" == true ]]; then continue; fi
        if should_include_file "$file"; then
            all_files+=("$file")
        fi
    done < <(find "$INPUT_DIR" -type f -print0 2>/dev/null | sort -z)

    # Apply --recent N
    if [[ "$TOP_N_RECENT" -gt 0 && ${#all_files[@]} -gt 0 ]]; then
        log_debug "Sorting ${#all_files[@]} files by mtime, picking top $TOP_N_RECENT"
        for f in "${all_files[@]}"; do
            echo "$(get_mtime_epoch "$f") $f"
        done | sort -rn | head -n "$TOP_N_RECENT" | while IFS= read -r line; do
            echo "${line#* }"
        done
        return 0
    fi

    if [[ ${#all_files[@]} -gt 0 ]]; then
        printf '%s\n' "${all_files[@]}"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# TOKEN BUDGET FILTER
# Applies --max-tokens: keeps adding files until budget is exhausted
# ─────────────────────────────────────────────────────────────────────────────

apply_token_budget() {
    local file_list="$1"
    local budget="$MAX_TOKENS"
    local running_total=0
    local included=0
    local skipped=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local fsize
        fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
        local ftokens
        ftokens=$(estimate_tokens "$fsize")

        if (( running_total + ftokens > budget )); then
            skipped=$((skipped + 1))
            continue
        fi

        running_total=$((running_total + ftokens))
        included=$((included + 1))
        echo "$file"
    done <<< "$file_list"

    if [[ "$skipped" -gt 0 ]]; then
        log_warn "Token budget ${C_CYAN}${budget}${C_NC}: included ${C_GREEN}${included}${C_NC} files, skipped ${C_YELLOW}${skipped}${C_NC} (would exceed limit)"
        log_info "Estimated tokens used: ${C_CYAN}~${running_total}${C_NC} / ${budget}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE SELECTION
# ─────────────────────────────────────────────────────────────────────────────

interactive_select() {
    local file_list="$1"
    local base_name
    base_name=$(basename "$INPUT_DIR")

    local display_list
    display_list=$(echo "$file_list" | while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel="${file#"$INPUT_DIR"/}"
        echo "${base_name}/${rel}"
    done)

    local selected
    selected=$(echo "$display_list" | fzf --multi \
        --header="TAB to select, ENTER to confirm" \
        2>/dev/null) || true

    if [[ -z "$selected" ]]; then
        log_warn "No files selected."
        exit 3
    fi

    echo "$selected" | while IFS= read -r line; do
        local rel
        rel=$(echo "$line" | sed "s|^${base_name}/||")
        echo "${INPUT_DIR}/${rel}"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# TREE
# ─────────────────────────────────────────────────────────────────────────────

generate_tree() {
    if command -v tree &>/dev/null; then
        local tree_args=("--charset=ascii")
        if [[ ${#EXCLUDE_DIRS[@]} -gt 0 ]]; then
            local tree_exclude
            tree_exclude=$(IFS='|'; echo "${EXCLUDE_DIRS[*]}")
            tree_args+=("-I" "$tree_exclude")
        fi
        tree "${tree_args[@]}" "$INPUT_DIR" 2>/dev/null || true
    else
        log_warn "'tree' not found. Install: sudo apt install tree" >&2
        find "$INPUT_DIR" -type f 2>/dev/null | sed "s|$INPUT_DIR/||" | sort
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# TABLE OF CONTENTS
# ─────────────────────────────────────────────────────────────────────────────

generate_toc() {
    local file_list="$1"
    local base_name
    base_name=$(basename "$INPUT_DIR")
    local idx=1

    echo "$file_list" | while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel="${file#"$INPUT_DIR"/}"
        printf "  %3d. %s/%s\n" "$idx" "$base_name" "$rel"
        idx=$((idx + 1))
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# STATISTICS (fixed IFS issue with uniq -c parsing)
# ─────────────────────────────────────────────────────────────────────────────

generate_stats() {
    local file_list="$1"
    local total_files=0 total_lines=0 total_bytes=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        total_files=$((total_files + 1))
        local fs fl
        fs=$(wc -c < "$file" 2>/dev/null || echo 0)
        fl=$(wc -l < "$file" 2>/dev/null || echo 0)
        total_bytes=$((total_bytes + fs))
        total_lines=$((total_lines + fl))
    done <<< "$file_list"

    echo "  Total files:       $total_files"
    echo "  Total lines:       $total_lines"
    echo "  Total size:        $(bytes_to_human $total_bytes)"
    if [[ "$ESTIMATE_TOKENS" == true ]]; then
        echo "  Est. tokens:       ~$(estimate_tokens $total_bytes)"
    fi
    echo ""
    echo "  Files by extension:"

    # Collect extensions, count, and format
    # Use explicit IFS=' ' for read to fix the parsing bug
    local ext_data
    ext_data=$(echo "$file_list" | while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        get_extension "$f"
    done | sort | uniq -c | sort -rn)

    echo "$ext_data" | while IFS=' ' read -r count ext; do
        # uniq -c output has leading spaces, so count may be empty on first read
        # trim and retry
        count=$(echo "$count" | xargs 2>/dev/null || echo "")
        ext=$(echo "$ext" | xargs 2>/dev/null || echo "")
        if [[ -z "$count" ]]; then continue; fi
        if [[ -z "$ext" ]]; then ext="(no ext)"; fi
        printf "    %-18s %s files\n" ".${ext}" "$count"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# FILE CONTENT RENDERER
# ─────────────────────────────────────────────────────────────────────────────

render_file_content() {
    local filepath="$1"

    if [[ "$HEADER_ONLY" -gt 0 ]]; then
        if [[ "$LINE_NUMBERS" == true ]]; then
            head -n "$HEADER_ONLY" "$filepath" 2>/dev/null | cat -n || echo "[Error reading file]"
        else
            head -n "$HEADER_ONLY" "$filepath" 2>/dev/null || echo "[Error reading file]"
        fi
        local total_lines
        total_lines=$(wc -l < "$filepath" 2>/dev/null || echo 0)
        if (( total_lines > HEADER_ONLY )); then
            echo ""
            echo "... [TRUNCATED: showing $HEADER_ONLY of $total_lines lines] ..."
        fi
    else
        if [[ "$LINE_NUMBERS" == true ]]; then
            cat -n "$filepath" 2>/dev/null || echo "[Error reading file]"
        else
            cat "$filepath" 2>/dev/null || echo "[Error reading file]"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUT: PLAIN TEXT
# ─────────────────────────────────────────────────────────────────────────────

output_text() {
    local file_list="$1"
    local base_name
    base_name=$(basename "$INPUT_DIR")
    local file_count
    file_count=$(echo "$file_list" | grep -c . || echo 0)
    local processed=0

    echo "$(separator '=' 80)"
    echo "  ${PROG_FULL_NAME} v${PROG_VERSION}"
    echo "  Source:     $INPUT_DIR"
    echo "  Generated:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Files:      $file_count"
    if [[ "$TOP_N_RECENT" -gt 0 ]]; then echo "  Mode:       Top $TOP_N_RECENT most recently modified"; fi
    if [[ -n "$SINCE_DATE" ]]; then echo "  Since:      $SINCE_DATE"; fi
    if [[ -n "$SEARCH_PATTERN" ]]; then echo "  Grep:       $SEARCH_PATTERN"; fi
    if [[ "$HEADER_ONLY" -gt 0 ]]; then echo "  Preview:    First $HEADER_ONLY lines per file"; fi
    if [[ "$MAX_TOKENS" -gt 0 ]]; then echo "  Token cap:  $MAX_TOKENS"; fi
    echo "$(separator '=' 80)"
    echo ""

    if [[ "$SHOW_TREE" == true ]]; then
        echo "$(separator '-' 80)"
        echo "  DIRECTORY STRUCTURE"
        echo "$(separator '-' 80)"
        echo ""
        generate_tree
        echo ""
        echo ""
    fi

    if [[ "$SHOW_TOC" == true ]]; then
        echo "$(separator '-' 80)"
        echo "  TABLE OF CONTENTS"
        echo "$(separator '-' 80)"
        echo ""
        generate_toc "$file_list"
        echo ""
        echo ""
    fi

    echo "$(separator '-' 80)"
    echo "  FILE CONTENTS"
    echo "$(separator '-' 80)"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel_path="${file#"$INPUT_DIR"/}"
        local display_path="${base_name}/${rel_path}"
        processed=$((processed + 1))

        if [[ "$SILENT" == false ]]; then
            printf "\r  > Processing: %d/%d" "$processed" "$file_count" >&2
        fi

        echo "$(separator '-' 80)"
        echo "FILE: ${display_path}"
        if [[ "$SHOW_METADATA" == true ]]; then
            local fsize fmod fperms
            fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
            fmod=$(get_mtime_display "$file")
            fperms=$(get_permissions "$file")
            echo "   Size: $(bytes_to_human $fsize) | Modified: $fmod | Perms: $fperms"
            if [[ "$ESTIMATE_TOKENS" == true ]]; then
                echo "   Est. tokens: ~$(estimate_tokens $fsize)"
            fi
        fi
        echo "$(separator '-' 80)"
        echo ""
        render_file_content "$file"
        echo ""
        echo ""
    done <<< "$file_list"

    if [[ "$SHOW_STATS" == true ]]; then
        echo "$(separator '=' 80)"
        echo "  STATISTICS"
        echo "$(separator '=' 80)"
        echo ""
        generate_stats "$file_list"
        echo ""
        echo "$(separator '=' 80)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUT: MARKDOWN
# ─────────────────────────────────────────────────────────────────────────────

output_markdown() {
    local file_list="$1"
    local base_name
    base_name=$(basename "$INPUT_DIR")
    local file_count
    file_count=$(echo "$file_list" | grep -c . || echo 0)
    local processed=0

    echo "# ${PROG_FULL_NAME}"
    echo ""
    echo "| Property | Value |"
    echo "|----------|-------|"
    echo "| Source | \`$INPUT_DIR\` |"
    echo "| Generated | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo "| Files | $file_count |"
    if [[ "$TOP_N_RECENT" -gt 0 ]]; then echo "| Mode | Top $TOP_N_RECENT recently modified |"; fi
    if [[ -n "$SINCE_DATE" ]]; then echo "| Since | $SINCE_DATE |"; fi
    if [[ -n "$SEARCH_PATTERN" ]]; then echo "| Grep | \`$SEARCH_PATTERN\` |"; fi
    if [[ "$MAX_TOKENS" -gt 0 ]]; then echo "| Token cap | $MAX_TOKENS |"; fi
    echo ""

    if [[ "$SHOW_TREE" == true ]]; then
        echo "## Directory Structure"
        echo ""
        echo '```'
        generate_tree
        echo '```'
        echo ""
    fi

    if [[ "$SHOW_TOC" == true ]]; then
        echo "## Table of Contents"
        echo ""
        local idx=1
        echo "$file_list" | while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local rel="${file#"$INPUT_DIR"/}"
            echo "${idx}. \`${base_name}/${rel}\`"
            idx=$((idx + 1))
        done
        echo ""
    fi

    echo "## File Contents"
    echo ""

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel_path="${file#"$INPUT_DIR"/}"
        local display_path="${base_name}/${rel_path}"
        local ext lang
        ext=$(get_extension "$file")
        lang=$(ext_to_lang "$ext")
        processed=$((processed + 1))

        if [[ "$SILENT" == false ]]; then
            printf "\r  > Processing: %d/%d" "$processed" "$file_count" >&2
        fi

        echo "### \`${display_path}\`"
        echo ""
        if [[ "$SHOW_METADATA" == true ]]; then
            local fsize fmod
            fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
            fmod=$(get_mtime_display "$file")
            local meta="> Size: $(bytes_to_human $fsize) | Modified: $fmod"
            if [[ "$ESTIMATE_TOKENS" == true ]]; then
                meta="$meta | ~$(estimate_tokens $fsize) tokens"
            fi
            echo "$meta"
            echo ""
        fi
        echo "\`\`\`${lang}"
        render_file_content "$file"
        echo '```'
        echo ""
    done <<< "$file_list"

    if [[ "$SHOW_STATS" == true ]]; then
        echo "## Statistics"
        echo ""
        echo '```'
        generate_stats "$file_list"
        echo '```'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUT: JSON
# ─────────────────────────────────────────────────────────────────────────────

output_json() {
    local file_list="$1"
    local base_name
    base_name=$(basename "$INPUT_DIR")
    local file_count
    file_count=$(echo "$file_list" | grep -c . || echo 0)
    local processed=0

    echo "{"
    echo "  \"generator\": \"${PROG_FULL_NAME} v${PROG_VERSION}\","
    echo "  \"source\": \"$(json_escape "$INPUT_DIR")\","
    echo "  \"generated\": \"$(date '+%Y-%m-%dT%H:%M:%S%z')\","
    echo "  \"total_files\": $file_count,"
    echo "  \"files\": ["

    local first=true
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel_path="${file#"$INPUT_DIR"/}"
        local display_path="${base_name}/${rel_path}"
        local ext fsize flines fmod
        ext=$(get_extension "$file")
        fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
        flines=$(wc -l < "$file" 2>/dev/null || echo 0)
        fmod=$(get_mtime_display "$file")
        processed=$((processed + 1))

        if [[ "$SILENT" == false ]]; then
            printf "\r  > Processing: %d/%d" "$processed" "$file_count" >&2
        fi

        local content
        if [[ "$HEADER_ONLY" -gt 0 ]]; then
            content=$(json_escape "$(head -n "$HEADER_ONLY" "$file" 2>/dev/null || echo "")")
        else
            content=$(json_escape "$(cat "$file" 2>/dev/null || echo "")")
        fi

        if [[ "$first" == true ]]; then
            first=false
        else
            echo ","
        fi

        echo "    {"
        echo "      \"path\": \"$(json_escape "$display_path")\","
        echo "      \"extension\": \"$ext\","
        echo "      \"size_bytes\": $fsize,"
        echo "      \"lines\": $flines,"
        echo "      \"modified\": \"$fmod\","
        if [[ "$ESTIMATE_TOKENS" == true ]]; then
            echo "      \"estimated_tokens\": $(estimate_tokens $fsize),"
        fi
        printf '      "content": "%s"\n' "$content"
        printf "    }"
    done <<< "$file_list"

    echo ""
    echo "  ]"
    echo "}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SPLIT OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

write_split_output() {
    local file_list="$1"
    local base_dir base_name name_no_ext ext
    base_dir=$(dirname "$OUTPUT_FILE")
    base_name=$(basename "$OUTPUT_FILE")
    name_no_ext="${base_name%.*}"
    ext="${base_name##*.}"
    if [[ "$name_no_ext" == "$ext" ]]; then ext=""; fi

    local total_files
    total_files=$(echo "$file_list" | grep -c . || echo 0)
    local total_parts=$(( (total_files + SPLIT_COUNT - 1) / SPLIT_COUNT ))
    local part=1 count=0
    local chunk_files=""

    log_info "Splitting: ${C_CYAN}$SPLIT_COUNT${C_NC} files per part (~${total_parts} parts)"

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        count=$((count + 1))

        if [[ -z "$chunk_files" ]]; then
            chunk_files="$file"
        else
            chunk_files="${chunk_files}"$'\n'"${file}"
        fi

        if (( count >= SPLIT_COUNT )); then
            local part_file
            if [[ -n "$ext" ]]; then
                part_file="${base_dir}/${name_no_ext}_part${part}.${ext}"
            else
                part_file="${base_dir}/${name_no_ext}_part${part}"
            fi
            safety_check "$part_file"
            { case "$OUTPUT_FORMAT" in
                text) output_text "$chunk_files" ;; markdown) output_markdown "$chunk_files" ;; json) output_json "$chunk_files" ;;
            esac; } > "$part_file"
            local ps; ps=$(wc -c < "$part_file")
            log_info "  Part $part: ${C_CYAN}$part_file${C_NC} ($count files, $(bytes_to_human $ps))"
            part=$((part + 1)); count=0; chunk_files=""
        fi
    done <<< "$file_list"

    if [[ -n "$chunk_files" ]]; then
        local part_file
        if [[ -n "$ext" ]]; then
            part_file="${base_dir}/${name_no_ext}_part${part}.${ext}"
        else
            part_file="${base_dir}/${name_no_ext}_part${part}"
        fi
        safety_check "$part_file"
        { case "$OUTPUT_FORMAT" in
            text) output_text "$chunk_files" ;; markdown) output_markdown "$chunk_files" ;; json) output_json "$chunk_files" ;;
        esac; } > "$part_file"
        local ps; ps=$(wc -c < "$part_file")
        log_info "  Part $part: ${C_CYAN}$part_file${C_NC} ($count files, $(bytes_to_human $ps))"
    fi
    log_info "Created ${C_GREEN}$part${C_NC} part files"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLIPBOARD
# ─────────────────────────────────────────────────────────────────────────────

copy_to_clipboard() {
    local file="$1"
    if command -v clip.exe &>/dev/null; then
        clip.exe < "$file"; log_info "Copied to clipboard (clip.exe)"
    elif command -v xclip &>/dev/null; then
        xclip -selection clipboard < "$file"; log_info "Copied to clipboard (xclip)"
    elif command -v xsel &>/dev/null; then
        xsel --clipboard --input < "$file"; log_info "Copied to clipboard (xsel)"
    elif command -v pbcopy &>/dev/null; then
        pbcopy < "$file"; log_info "Copied to clipboard (pbcopy)"
    else
        log_warn "No clipboard tool found."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    local start_time
    start_time=$(date +%s)

    parse_args "$@"
    validate

    # Banner
    if [[ "$SILENT" == false && "$LIST_FILES_ONLY" == false ]]; then
        echo "" >&2
        echo "${C_BOLD}${C_BLUE}  ${PROG_FULL_NAME} v${PROG_VERSION}${C_NC}" >&2
        echo "  ${C_DIM}$(separator '-' 50)${C_NC}" >&2
        echo "  Source:  ${C_CYAN}$INPUT_DIR${C_NC}" >&2
        if [[ -n "$OUTPUT_FILE" ]]; then
            echo "  Output:  ${C_CYAN}$OUTPUT_FILE${C_NC}" >&2
        fi
        echo "  Format:  ${C_CYAN}$OUTPUT_FORMAT${C_NC}" >&2
        if [[ ${#INCLUDE_EXTS[@]} -gt 0 ]]; then
            echo "  Include: ${C_GREEN}$(join_arr ', ' "${INCLUDE_EXTS[@]}")${C_NC}" >&2
        fi
        if [[ "$TOP_N_RECENT" -gt 0 ]]; then
            echo "  Recent:  ${C_YELLOW}top $TOP_N_RECENT files${C_NC}" >&2
        fi
        if [[ -n "$SINCE_DATE" ]]; then
            echo "  Since:   ${C_YELLOW}$SINCE_DATE${C_NC}" >&2
        fi
        if [[ -n "$SEARCH_PATTERN" ]]; then
            echo "  Grep:    ${C_YELLOW}$SEARCH_PATTERN${C_NC}" >&2
        fi
        if [[ "$HEADER_ONLY" -gt 0 ]]; then
            echo "  Preview: ${C_YELLOW}first $HEADER_ONLY lines${C_NC}" >&2
        fi
        if [[ "$SPLIT_COUNT" -gt 0 ]]; then
            echo "  Split:   ${C_YELLOW}$SPLIT_COUNT files per part${C_NC}" >&2
        fi
        if [[ "$MAX_TOKENS" -gt 0 ]]; then
            echo "  Budget:  ${C_YELLOW}$MAX_TOKENS tokens max${C_NC}" >&2
        fi
        if [[ "$MAX_FILE_TOKENS" -gt 0 ]]; then
            echo "  Per-file: ${C_YELLOW}$MAX_FILE_TOKENS tokens max${C_NC}" >&2
        fi
        echo "  ${C_DIM}Read-only mode: source files are never modified${C_NC}" >&2
        echo "" >&2
    fi

    # Collect files
    log_step "Collecting files..."
    local file_list
    file_list=$(collect_files)

    if [[ -z "$file_list" ]]; then
        log_warn "No files matched the given criteria."
        exit 3
    fi

    local file_count
    file_count=$(echo "$file_list" | grep -c . || echo 0)
    log_info "Found ${C_BOLD}${C_GREEN}$file_count${C_NC} files"

    # Apply token budget
    if [[ "$MAX_TOKENS" -gt 0 ]]; then
        file_list=$(apply_token_budget "$file_list")
        if [[ -z "$file_list" ]]; then
            log_warn "No files fit within the token budget of $MAX_TOKENS"
            exit 3
        fi
        file_count=$(echo "$file_list" | grep -c . || echo 0)
    fi

    # Interactive selection
    if [[ "$INTERACTIVE" == true ]]; then
        log_step "Launching interactive selector..."
        file_list=$(interactive_select "$file_list")
        file_count=$(echo "$file_list" | grep -c . || echo 0)
        log_info "Selected ${C_GREEN}$file_count${C_NC} files"
    fi

    # ── List mode ──
    if [[ "$LIST_FILES_ONLY" == true ]]; then
        local base_name
        base_name=$(basename "$INPUT_DIR")
        echo ""
        printf "  ${C_BOLD}%4s | %10s | %-19s | Path${C_NC}\n" "#" "Size" "Modified"
        echo "  -----+------------+---------------------+------------------------------"

        local idx=1
        echo "$file_list" | while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local rel="${file#"$INPUT_DIR"/}"
            local fsize fmod
            fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
            fmod=$(get_mtime_display "$file")
            local token_info=""
            if [[ "$ESTIMATE_TOKENS" == true ]]; then
                token_info=" (~$(estimate_tokens $fsize) tok)"
            fi
            printf "  %4d | %10s | %s | %s/%s%s\n" \
                "$idx" "$(bytes_to_human $fsize)" "$fmod" "$base_name" "$rel" "$token_info"
            idx=$((idx + 1))
        done

        echo "  -----+------------+---------------------+------------------------------"
        echo "  ${C_BOLD}Total: $file_count files${C_NC}"
        echo ""
        exit 0
    fi

    # ── Dry run ──
    if [[ "$DRY_RUN" == true ]]; then
        local base_name
        base_name=$(basename "$INPUT_DIR")
        echo "" >&2
        log_info "${C_YELLOW}DRY RUN${C_NC} -- files that would be included:"
        echo "" >&2

        echo "$file_list" | while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            local rel="${file#"$INPUT_DIR"/}"
            local fsize fmod
            fsize=$(wc -c < "$file" 2>/dev/null || echo 0)
            fmod=$(get_mtime_display "$file")
            local token_info=""
            if [[ "$ESTIMATE_TOKENS" == true ]]; then
                token_info="  (~$(estimate_tokens $fsize) tokens)"
            fi
            echo "  ${C_CYAN}$(printf '%10s' "$(bytes_to_human $fsize)")${C_NC}  ${C_DIM}$fmod${C_NC}  ${base_name}/${rel}${token_info}" >&2
        done

        echo "" >&2
        log_info "Total: ${C_BOLD}$file_count${C_NC} files would be aggregated"
        exit 0
    fi

    # ── Write output ──
    if [[ "$SPLIT_COUNT" -gt 0 ]]; then
        log_step "Writing split output ($SPLIT_COUNT files per part)..."
        write_split_output "$file_list"
    else
        log_step "Writing $OUTPUT_FORMAT output..."
        { case "$OUTPUT_FORMAT" in
            text) output_text "$file_list" ;; markdown) output_markdown "$file_list" ;; json) output_json "$file_list" ;;
        esac; } > "$OUTPUT_FILE"
    fi

    # Clear progress
    if [[ "$SILENT" == false ]]; then
        printf "\r%-80s\r" "" >&2
    fi

    # Clipboard
    if [[ "$COPY_TO_CLIPBOARD" == true && "$SPLIT_COUNT" -eq 0 ]]; then
        copy_to_clipboard "$OUTPUT_FILE"
    fi

    # Summary
    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    echo "" >&2

    if [[ "$SPLIT_COUNT" -eq 0 ]]; then
        local output_size
        output_size=$(wc -c < "$OUTPUT_FILE")
        log_info "Done in ${elapsed}s"
        log_info "Output:  ${C_BOLD}${C_CYAN}$OUTPUT_FILE${C_NC} ($(bytes_to_human "$output_size"))"
        if [[ "$ESTIMATE_TOKENS" == true ]]; then
            log_info "Tokens:  ~$(estimate_tokens "$output_size") (estimated)"
        fi
    else
        log_info "Done in ${elapsed}s"
    fi
    log_info "Files:   ${C_BOLD}${C_GREEN}$file_count${C_NC}"
    echo "" >&2
}

main "$@"
