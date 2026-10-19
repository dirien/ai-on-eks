# Sourced (hidden) at the start of openhands-demo.tape. VHS inherits
# record.sh's environment (ambient AWS credentials, or `pulumi env run` when
# ESC_ENV is set), so kubectl already has AWS credentials; nothing here
# prints them.
cd "$(dirname "${BASH_SOURCE[0]}")"
export OPENHANDS_DEMO_IN_ESC=1
export KUBECTL_EXTERNAL_DIFF= HISTFILE=/dev/null
export TERM=xterm-256color
# kubectl exec -t passes the VHS terminal size to the pod.
# ASCII prompt: with a multi-byte prompt glyph readline miscounted the width
# and garbled long commands where they wrap.
PS1='\[\e[1;38;2;252;186;35m\]$\[\e[0m\] '
PROMPT_COMMAND=
unset HISTFILE
