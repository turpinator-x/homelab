# shellcheck shell=sh
# Shared preflight for scripts/validate.sh and the scripts/test-*.sh and scripts/check-*.sh it runs.
# Source it (POSIX sh: bash and busybox ash both work), then call:
#   require_tools tool...     normalise PATH, resolve every tool with `command -v`, and if any is missing print ONE
#                             message (the missing names, the PATH searched, the fix) and exit 1, before anything runs
#   print_tools tool...       print "name: resolved path" lines (the header validate.sh shows)
#   link_tools dir tool...    symlink the real (absolute) path of each tool into dir, for tests that build a
#                             restricted tool directory; a missing tool fails with the same message
# Every tool must be a program file on PATH (list no shell builtins such as printf).
# Why: a shell started with a PATH that lacks /usr/bin (a release runner, cron, `env -i`) used to run the tests
# until one of them hit "required command 'awk' not found" deep inside, followed by knock-on errors.
# REQUIRE_TOOLS_NO_NORMALIZE=1 skips the PATH normalisation (the preflight tests use it to restrict PATH on purpose).
# Do not use external commands here (dirname, sed ...): the PATH may be broken when this runs.

normalize_path() {
  _np_add=
  _np_ifs=$IFS
  IFS=:
  for _np_d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
    case ":${PATH:-}:" in
      *":$_np_d:"*) ;;
      *) [ -d "$_np_d" ] && _np_add=${_np_add:+$_np_add:}$_np_d ;;
    esac
  done
  IFS=$_np_ifs
  # prepend only the missing standard directories; every existing entry (mise shims included) keeps its place
  if [ -n "$_np_add" ]; then PATH=$_np_add${PATH:+:$PATH}; fi
  export PATH
  return 0
}

# the absolute path of an executable file for a tool, or non-zero. `command -v` first; when it answers with a bare name
# (a shell function, alias or builtin shadows the program, as in some interactive setups) PATH is searched for the file
# instead, because a restricted tool directory and a child process need a real file, not a shell function.
_rt_resolve() {
  _rt_p=$(command -v "$1" 2> /dev/null) || _rt_p=
  case $_rt_p in
    /*) [ -x "$_rt_p" ] && [ ! -d "$_rt_p" ] && { printf '%s\n' "$_rt_p"; return 0; } ;;
  esac
  _rs_ifs=$IFS
  IFS=:
  for _rs_d in ${PATH:-}; do
    [ -n "$_rs_d" ] || continue
    if [ -x "$_rs_d/$1" ] && [ ! -d "$_rs_d/$1" ]; then
      IFS=$_rs_ifs
      printf '%s\n' "$_rs_d/$1"
      return 0
    fi
  done
  IFS=$_rs_ifs
  return 1
}

_rt_fail() {
  printf '%s\n' "preflight: required tool(s) not found: $1" >&2
  printf '%s\n' "  needed by:     ${REQUIRE_TOOLS_WHO:-${0##*/}}" >&2
  printf '%s\n' "  PATH searched: ${PATH:-<unset>}" >&2
  # shellcheck disable=SC2016 # $PATH stays literal: it is the text of the fix
  printf '%s\n' '  fix:           export PATH=/usr/local/bin:/usr/bin:/bin:$PATH   (then run it again; install any tool that is still missing)' >&2
  exit 1
}

require_tools() {
  [ -n "${REQUIRE_TOOLS_NO_NORMALIZE:-}" ] || normalize_path
  _rt_missing=
  for _rt_t in "$@"; do
    _rt_resolve "$_rt_t" > /dev/null || _rt_missing=${_rt_missing:+$_rt_missing }$_rt_t
  done
  [ -z "$_rt_missing" ] || _rt_fail "$_rt_missing"
  return 0
}

print_tools() {
  for _rt_t in "$@"; do
    printf '  %-12s %s\n' "$_rt_t" "$(_rt_resolve "$_rt_t" || echo '(not found)')"
  done
}

link_tools() {
  [ -n "${REQUIRE_TOOLS_NO_NORMALIZE:-}" ] || normalize_path
  _lt_dir=$1
  shift
  _rt_missing=
  for _rt_t in "$@"; do
    if _lt_p=$(_rt_resolve "$_rt_t"); then
      ln -sf "$_lt_p" "$_lt_dir/$_rt_t"
    else
      _rt_missing=${_rt_missing:+$_rt_missing }$_rt_t
    fi
  done
  [ -z "$_rt_missing" ] || _rt_fail "$_rt_missing"
  return 0
}
