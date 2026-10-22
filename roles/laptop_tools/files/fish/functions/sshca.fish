function sshca --description 'SSH-Zertifikat von step-ca holen (Authelia-Login + 2FA), wenn keins da ist oder es in <24 h ablaeuft'
    set -l rest (ssh-add -L 2>/dev/null | string match -r '.*-cert-v01@openssh\.com .*' | head -1 | ssh-keygen -L -f - 2>/dev/null | string match -r 'Valid: from \S+ to (\S+)')[2]
    if test -n "$rest"; and test (math (date -d $rest +%s) - (date +%s)) -gt 86400; and not contains -- -f $argv
        echo "SSH-Zertifikat gueltig bis $rest"
        return 0
    end
    step-cli ssh login gurkesalat --provisioner authelia
end
