#!/usr/bin/env bash
# Undoes release side effects even if the Ruby process was killed: restores the keychain search
# list, deletes the temporary keychain, restores ~/.netrc and removes the work directory.
# Exits non-zero if any step fails so a cleanup failure is never silent.
set -uo pipefail

input_temp=${RUNNER_TEMP:?RUNNER_TEMP is required}
work=${RELEASE_WORK:?RELEASE_WORK is required}
task_home=${HOME:?}
failed=0

reject_path() { echo "::error::Unsafe release cleanup path; recovery state retained." >&2; exit 1; }
valid_path() {
    [[ "$1" == /* && "$1" != / && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || return 1
    case "/$1/" in *'/../'*|*'/./'*) return 1 ;; esac
}
valid_path "$input_temp" && valid_path "$work" || reject_path
[[ -d "$input_temp" && ! -L "$input_temp" && -O "$input_temp" ]] || reject_path
temp=$(cd -- "$input_temp" && pwd -P) || reject_path
case "$work" in
    "$input_temp"/*) work="$temp/${work#"$input_temp"/}" ;;
    "$temp"/*) ;;
    *) reject_path ;;
esac
state="$temp/release-state"

# 復旧処理より先に全経路を検証し、別の実行が所有する場所へ触れない。
owned_path() {
    local path=$1 kind=$2 relative cursor part
    valid_path "$path" || return 1
    [[ "$path" == "$temp"/* ]] || return 1
    relative=${path#"$temp"/}
    cursor=$temp
    while [[ -n "$relative" ]]; do
        part=${relative%%/*}
        [[ -n "$part" ]] || return 1
        cursor="$cursor/$part"
        [[ ! -L "$cursor" ]] || return 1
        [[ ! -e "$cursor" || -O "$cursor" ]] || return 1
        if [[ "$relative" == */* ]]; then
            [[ ! -e "$cursor" || -d "$cursor" ]] || return 1
            relative=${relative#*/}
        else
            [[ ! -e "$cursor" || "$kind" == file || -d "$cursor" ]] || return 1
            relative=''
        fi
    done
}
owned_path "$work" directory && owned_path "$state" directory || reject_path
[[ "$work" != "$state" && "$work" != "$state"/* ]] || reject_path
for journal in original.txt path netrc-installed; do
    owned_path "$state/$journal" file || reject_path
    [[ ! -e "$state/$journal" || -f "$state/$journal" ]] || reject_path
done
keychain=''
if [[ -f "$state/path" ]]; then
    IFS= read -r keychain < "$state/path" || [[ -n "$keychain" ]] || reject_path
    case "$keychain" in "$input_temp"/*) keychain="$temp/${keychain#"$input_temp"/}" ;; esac
    [[ "$keychain" == "$work"/* ]] && owned_path "$keychain" file || reject_path
fi

# 署名情報を持つ親から呼ばれても、復旧用の子プロセスには渡さない。
clean_command() {
    /usr/bin/env -i HOME="$task_home" PATH="${PATH:?}" RUNNER_TEMP="$temp" RELEASE_WORK="$work" "$@"
}

if [[ -f "$state/original.txt" ]]; then
    original=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && original+=("$line")
    done < "$state/original.txt"
    # macOS の Bash では空配列を展開できないため、空の元リストも明示的に復元する。
    if [[ "${#original[@]}" -eq 0 ]]; then
        clean_command security list-keychains -d user -s >/dev/null 2>&1 || { echo "::error::Could not restore the keychain search list." >&2; failed=1; }
    else
        clean_command security list-keychains -d user -s "${original[@]}" >/dev/null 2>&1 || { echo "::error::Could not restore the keychain search list." >&2; failed=1; }
    fi
    if [[ -f "$state/path" ]]; then
        clean_command security delete-keychain "$keychain" >/dev/null 2>&1 || [[ ! -e "$keychain" ]] || { echo "::error::Could not delete the temporary keychain." >&2; failed=1; }
    fi
fi

if [[ -e "$state/original.netrc" || -L "$state/original.netrc" ]]; then
    clean_command rm -f "$task_home/.netrc" && clean_command mv "$state/original.netrc" "$task_home/.netrc" || { echo "::error::Could not restore ~/.netrc; recovery state retained." >&2; failed=1; }
elif [[ -f "$state/netrc-installed" ]] && [[ "$(clean_command cat "$state/netrc-installed")" != original-pending ]]; then
    clean_command rm -f "$task_home/.netrc" || failed=1
fi

clean_command rm -rf "$work" || failed=1
if [[ "$failed" -eq 0 ]]; then clean_command rm -rf "$state" || failed=1; fi
[[ -e "$work" ]] && failed=1
exit "$failed"
