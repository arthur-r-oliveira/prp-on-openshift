# Sourced, not run. Gives the test and Day-2 scripts one way to run a
# command on either SNO node, whichever access the lab offers:
#
#   NODE_EXEC=ssh       (default) ssh $SSH_USER@$NODE_{A,B}_IP - the KVM lab,
#                       where the runner's key is baked into the nodes.
#   NODE_EXEC=oc-debug  oc debug node/$NODE_{A,B}_HOSTNAME - any lab where
#                       only the kubeconfigs are at hand (e.g. SNOs installed
#                       elsewhere and handed over for Day-2). Needs no node
#                       SSH key; costs ~10s of debug-pod startup per call.
#
# The debug pod runs on the host network and chroots into /host, so ping
# over prp0, `ip link set` and debugfs reads behave as they do over SSH.
#
# Callers set NODE_{A,B}_IP, KUBECONFIG_{A,B} and NODE_{A,B}_HOSTNAME first.

NODE_EXEC="${NODE_EXEC:-ssh}"
SSH_USER="${SSH_USER:-core}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)

# node_sh <a|b> <command...>
node_sh() {
  local side="$1"; shift
  local ip kc host
  if [ "$side" = a ]; then
    ip="$NODE_A_IP" kc="$KUBECONFIG_A" host="$NODE_A_HOSTNAME"
  else
    ip="$NODE_B_IP" kc="$KUBECONFIG_B" host="$NODE_B_HOSTNAME"
  fi
  case "$NODE_EXEC" in
    ssh) ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "$*" ;;
    # stderr is dropped: it carries the debug pod's own chatter, which
    # would otherwise land in output the callers parse.
    oc-debug) KUBECONFIG="$kc" oc debug -q "node/$host" -- chroot /host sh -c "$*" 2>/dev/null ;;
    *) echo "unknown NODE_EXEC=$NODE_EXEC (want ssh or oc-debug)" >&2; return 2 ;;
  esac
}
