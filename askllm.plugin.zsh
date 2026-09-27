# askllm — ask an LLM for shell commands right from the zsh prompt.
#
#   how do I list listening ports?     -> put one command into the prompt
#   show disk usage of this dir?!      -> run one command (unless it's risky)
#   git: see last commit??             -> choose from up to 6 commands (1-6)
#   git: undo last commit??!           -> choose and run (unless it's risky)
#
# Escape the trailing `?` (e.g. `ls file\?`) to run a line as a normal command.
# Requires: curl, jq and $OPENAI_ACCESS_TOKEN.

zmodload zsh/zleparameter 2>/dev/null

: ${ASKLLM_MODEL:=gpt-6-luna}
: ${ASKLLM_API_URL:=https://api.openai.com/v1/chat/completions}
: ${ASKLLM_MAX_LEN:=250}      # only lines shorter than this are treated as questions
: ${ASKLLM_TIMEOUT:=30}       # seconds
: ${ASKLLM_PREFILL:=1}        # 1: put suggested command into the prompt, 0: only print it

_askllm_detect_os() {
  case $OSTYPE in
    darwin*) print -r -- "macOS $(sw_vers -productVersion 2>/dev/null)" ;;
    linux*)
      if [[ -r /etc/os-release ]]; then
        (. /etc/os-release; print -r -- "Linux (${PRETTY_NAME:-unknown distribution})")
      else
        print -r -- "Linux"
      fi ;;
    *) print -r -- $OSTYPE ;;
  esac
}
typeset -g _ASKLLM_OS=$(_askllm_detect_os)

# $1: "single" or "multi"
_askllm_system_prompt() {
  local count_rule
  if [[ $1 == multi ]]; then
    count_rule='Return up to 6 alternative commands, typically 2 to 4: only genuinely different useful options (the fewer the better), best one first.'
  else
    count_rule='Return exactly one command: the single best solution.'
  fi
  cat <<EOF
You turn questions typed at an interactive shell prompt into ready-to-run command lines.

Environment: ${_ASKLLM_OS} / zsh ${ZSH_VERSION}

The user most likely asks how to do something on the command line. Rules:
- ${count_rule}
- Every command must work as-is in this shell on this OS (mind BSD vs. GNU flags on macOS). Prefer tools installed by default.
- One line per command; chain with && or pipes if needed. No explanations or comments inside the command.
- Avoid placeholders. If one is unavoidable, write it as <NAME> so the user notices it.
- "description": what the command does, at most 60 characters.
- "dangerous": true if the command deletes, overwrites, moves or modifies files or data, changes git history or remotes (commit, reset, rebase, push, clean, …), changes permissions or system settings, installs or removes software, kills processes, uses sudo or has any other side effect. false only for read-only commands.
- If the question cannot be answered with a command, return an empty "commands" list and a short answer in "note".

Respond with JSON only, exactly in this shape:
{"commands":[{"command":"...","description":"...","dangerous":false}],"note":""}
EOF
}

# $1: "single" or "multi", $2: question. Prints the model's JSON answer.
_askllm_request() {
  if [[ -z $OPENAI_ACCESS_TOKEN ]]; then
    print -r -- "askllm: \$OPENAI_ACCESS_TOKEN is not set" >&2
    return 1
  fi
  local body resp err
  body=$(jq -n --arg model "$ASKLLM_MODEL" --arg sys "$(_askllm_system_prompt $1)" --arg q "$2" '{
    model: $model,
    response_format: {type: "json_object"},
    messages: [{role: "system", content: $sys}, {role: "user", content: $q}]
  }') || return 1
  # header via process substitution keeps the token out of `ps`
  resp=$(curl -sS --max-time $ASKLLM_TIMEOUT "$ASKLLM_API_URL" \
    -H @<(print -r -- "Authorization: Bearer $OPENAI_ACCESS_TOKEN") \
    -H 'Content-Type: application/json' \
    --data-binary @- <<<"$body") || return 1
  err=$(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null)
  if [[ -n $err ]]; then
    print -r -- "askllm: $err" >&2
    return 1
  fi
  jq -er '.choices[0].message.content | fromjson | tojson' <<<"$resp" 2>/dev/null || {
    print -r -- "askllm: unexpected response: ${resp[1,300]}" >&2
    return 1
  }
}

# Local safety net on top of the model's "dangerous" flag: returns 0 if the
# command should not be executed without review.
_askllm_is_risky() {
  setopt localoptions extendedglob
  local c=$1
  c=${c//[0-9&]#>[[:space:]]#\/dev\/null/}
  c=${c//[0-9]#>&[0-9-]/}
  [[ $c == *'>'* ]] && return 0   # redirection into a file, or a <PLACEHOLDER>
  [[ $c == *(-delete|-exec|-execdir|sed\ -i|perl\ -[a-z]#i|xargs)* ]] && return 0
  [[ $c =~ '\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da|k)?sh([[:space:]]|$)' ]] && return 0
  local re='(^|[;&|(`[:space:]])(sudo|doas|su|rm|rmdir|unlink|mv|cp|ln|dd|mkfs[.a-z0-9]*|shred|truncate|touch|mkdir|chmod|chown|chgrp|kill|killall|pkill|reboot|shutdown|halt|launchctl|systemctl|service|diskutil|crontab|tee|eval|defaults[[:space:]]+(write|delete)|brew[[:space:]]+(install|uninstall|remove|upgrade|link|unlink)|apt|apt-get|dnf|yum|pacman|port|pip3?[[:space:]]+(install|uninstall)|npm[[:space:]]+(install|i|uninstall|publish|update)|docker[[:space:]]+(rm|rmi|kill|stop|prune|system)|git[[:space:]]+(reset|rebase|push|clean|checkout|switch|restore|revert|commit|merge|pull|rm|mv|stash|am|apply|cherry-pick|gc|prune|filter-branch|filter-repo|init|branch[[:space:]]+-[dDmM]|tag[[:space:]]+-d|remote[[:space:]]+(add|remove|rm|set-url)|config))([[:space:]]|$)'
  [[ $c =~ $re ]]
}

# The line ends with `?` but is really a glob matching existing files (e.g. `ls file?`)
_askllm_is_glob() {
  local w=${${(z)1}[-1]}
  [[ -n $(setopt nullglob; print -rl -- ${~w} 2>/dev/null) ]]
}

_askllm_accept_line() {
  setopt localoptions extendedglob
  local line=$BUFFER mode
  case $line in
    *'??!') mode=multi-exec ;;
    *'??')  mode=multi ;;
    *'?!')  mode=exec ;;
    *'?')   mode=single ;;
  esac
  local question=${line%%[?!]##}
  if [[ -z $mode || -n $ASKLLM_DISABLE || ${#line} -ge $ASKLLM_MAX_LEN \
        || -z ${question//[[:space:]]/} || $question == *'\' ]] || _askllm_is_glob "$line"; then
    zle _askllm_orig_accept_line
    return
  fi

  print -rs -- "$line"   # keep the question in the history
  zle -I
  print -rn -- $'\e[2m'"asking ${ASKLLM_MODEL}…"$'\e[0m'
  local content
  content=$(_askllm_request ${mode%-exec} "${question}?")
  local rc=$?
  print -rn -- $'\r\e[K'
  if (( rc )) || [[ -z $content ]]; then
    BUFFER=$line; CURSOR=$#BUFFER
    return
  fi

  local -a cmds descs dangers
  eval "cmds=( $(jq -r '[.commands[:6][] | .command // "" | gsub("\n"; " ")] | @sh' <<<"$content") )"
  eval "descs=( $(jq -r '[.commands[:6][] | .description // ""] | @sh' <<<"$content") )"
  eval "dangers=( $(jq -r '[.commands[:6][] | .dangerous == true | tostring] | @sh' <<<"$content") )"
  local note=$(jq -r '.note // empty' <<<"$content")
  [[ -n $note ]] && print -r -- $'\e[2m'"# $note"$'\e[0m'
  if (( ! $#cmds )); then
    BUFFER=''
    return
  fi

  local i=1
  if [[ $mode == multi* ]]; then
    print -r -- "The following commands can be used:"
    for (( i = 1; i <= $#cmds; i++ )); do
      print -r -- "$i. $cmds[i]  "$'\e[2m'"# $descs[i]"$'\e[0m'"${${dangers[i]:#false}:+ ⚠}"
    done
    print -rn -- $'\e[2m'"select 1-$#cmds (any other key cancels): "$'\e[0m'
    # after `zle -I` the tty is in cooked mode; switch to raw for a single keypress
    local key tty_state=$(stty -g </dev/tty)
    stty -icanon -echo min 1 </dev/tty
    read -k 1 key </dev/tty
    stty $tty_state </dev/tty
    print -r -- "$key"
    if [[ $key != [1-9] ]] || (( key > $#cmds )); then
      BUFFER=''
      return
    fi
    i=$key
  fi

  local cmd=$cmds[i]
  if [[ $mode == *exec ]]; then
    if [[ $dangers[i] == false ]] && ! _askllm_is_risky "$cmd"; then
      BUFFER=$cmd
      zle _askllm_orig_accept_line
      return
    fi
    print -r -- $'\e[33m'"# ${descs[i]:-This command may change files or system state}. Not executed: please review it and press Enter to run."$'\e[0m'
    BUFFER=$cmd; CURSOR=$#BUFFER
    return
  fi

  [[ $mode == single ]] && print -r -- $'\e[2m'"# $descs[i]"$'\e[0m'
  if (( ASKLLM_PREFILL )); then
    BUFFER=$cmd; CURSOR=$#BUFFER
  else
    [[ $mode == single ]] && print -r -- "$cmd"
    BUFFER=''
  fi
}

# Wrap whatever accept-line currently is (other plugins may have wrapped it too).
if [[ ${widgets[accept-line]} == user:_askllm_accept_line ]]; then
  :  # already loaded
elif [[ ${widgets[accept-line]} == user:* ]]; then
  zle -A accept-line _askllm_orig_accept_line
  zle -N accept-line _askllm_accept_line
else
  zle -A .accept-line _askllm_orig_accept_line
  zle -N accept-line _askllm_accept_line
fi
