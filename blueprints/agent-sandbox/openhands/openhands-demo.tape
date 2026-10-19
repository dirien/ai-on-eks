# OpenHands on a pre-warmed Kubernetes Agent Sandbox (EKS), raw take.
# KCD UK 2026, "Your AI Agent Needs More Than a Pod".
#
# Every line on screen is a command typed by this tape or the unmodified
# stdout/stderr of that command. No comments, no custom formatting, no output
# post-processing except `| head -n N` on two commands (see README). Real time:
# each Wait waits for the shell prompt to come back after a real command.
# Hide covers only the shell setup before the first visible command (start the
# `script` session log with a UTF-8 locale, source tape-env.sh for the prompt
# and directory).
#
# Run through ./record.sh (VHS, under `pulumi env run` if ESC_ENV is set, then
# ffmpeg).

Output out/openhands-demo-raw.mp4

Require kubectl
Require script

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 28
Set LineHeight 1.0
Set Width 1920
Set Height 1080
Set Padding 40
Set Framerate 30
Set TypingSpeed 22ms
Set CursorBlink false
Set WaitTimeout 300s
Set Theme { "name": "Pulumi Dark", "background": "#231f33", "foreground": "#ebebff", "cursor": "#fcba23", "selection": "#492e8e", "black": "#392960", "red": "#ff676e", "green": "#4ade80", "yellow": "#fcba23", "blue": "#9077f3", "magenta": "#a697fc", "cyan": "#02d9c0", "white": "#ebebff", "brightBlack": "#a29dc4", "brightRed": "#ff9fa4", "brightGreen": "#84f1ac", "brightYellow": "#fdcf4c", "brightBlue": "#a697fc", "brightMagenta": "#c3bdff", "brightCyan": "#1efad9", "brightWhite": "#f5f5ff" }

Hide
Type "export LANG=C.UTF-8 LC_ALL=C.UTF-8; script -qf --log-timing out/session.timing out/session.log"
Enter
Sleep 1s
Type "source ./tape-env.sh && clear"
Enter
Sleep 1s
Show

Sleep 500ms
Type "kubectl get sandboxwarmpool -n agent-sandboxes"
Enter
Sleep 1s
Wait+Line /^\$\s*$/
Sleep 2s

Type "kubectl apply -f manifests/40-claim.yaml && kubectl wait -n agent-sandboxes sandboxclaim/guardrails --for=condition=Ready"
Enter
Sleep 1s
Wait+Line /^\$\s*$/
Sleep 1s

Type "POD=$(kubectl get sandboxclaim guardrails -n agent-sandboxes -o jsonpath='{.status.sandbox.name}')"
Enter
Sleep 1s
Wait+Line /^\$\s*$/

Type "kubectl exec -n agent-sandboxes $POD -- uname -r"
Enter
Sleep 1s
Wait+Line /^\$\s*$/
Sleep 1s

Type "kubectl exec -n agent-sandboxes $POD -- dmesg | head -n 3"
Enter
Sleep 1s
Wait+Line /^\$\s*$/
Sleep 1.5s

Type "kubectl exec -n agent-sandboxes $POD -- ls /var/run/secrets/kubernetes.io/serviceaccount"
Enter
Sleep 1s
Wait+Line /^\$\s*$/
Sleep 1.5s

Type "kubectl exec -n agent-sandboxes $POD -- curl -sSI -m 5 https://pypi.org/simple/ | head -n 1"
Enter
Sleep 1s
Wait+Line /^\$\s*$/
Sleep 1s

Type "kubectl exec -n agent-sandboxes $POD -- curl -sSI -m 5 https://example.com"
Enter
Sleep 1s
Wait+Line@30s /^\$\s*$/
Sleep 1s

Type "RELAY=$(kubectl get svc hubble-relay -n kube-system -o jsonpath='{.spec.clusterIP}')"
Enter
Sleep 1s
Wait+Line /^\$\s*$/

Type "kubectl exec -n kube-system ds/cilium -c cilium-agent -- hubble observe --server $RELAY:80 --pod agent-sandboxes/$POD --verdict DROPPED --last 2"
Enter
Sleep 1s
Wait+Line@60s /^\$\s*$/
Sleep 3s

Type "kubectl exec -it -n openhands-client deploy/oh-client -- python run.py"
Enter
Sleep 1s
Wait+Line@300s /^\$\s*$/
Sleep 6s
