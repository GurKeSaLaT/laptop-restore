# T51a: Beim Start jeder interaktiven Shell (kitty) pruefen, wie lange das SSH-Zertifikat
# im ssh-agent noch gilt. Warnung bei < 24 h, abgelaufen oder keinem Zertifikat.
status is-interactive; or exit

function __sshca_pruefen
    set -l ende 0
    # alle Zertifikate im Agent, das am laengsten gueltige zaehlt
    for zeile in (ssh-add -L 2>/dev/null | string match -r -- '.*-cert-v01@openssh\.com .*')
        set -l bis (echo $zeile | ssh-keygen -L -f - 2>/dev/null | string match -r 'Valid: from \S+ to (\S+)')[2]
        test -n "$bis"; or continue
        set -l t (date -d $bis +%s 2>/dev/null); or continue
        test $t -gt $ende; and set ende $t
    end

    set -l rest (math $ende - (date +%s))
    if test $ende -gt 0 -a $rest -gt 86400
        return 0
    end

    set -l titel
    if test $ende -eq 0
        set titel "Kein SSH-Zertifikat im Agent (abgelaufen oder nach Neustart weg)"
    else if test $rest -le 0
        set titel "SSH-Zertifikat ist abgelaufen"
    else
        set -l h (math -s0 $rest / 3600)
        set -l m (math -s0 \($rest % 3600\) / 60)
        set titel "SSH-Zertifikat laeuft in $h h $m min ab ("(date -d @$ende '+%d.%m. %H:%M')")"
    end

    # feste Farbe statt Schema-Gelb (im kitty-Schema ist "yellow" fast weiss)
    set_color --bold black --background ff9e00
    echo " ⚠  $titel "
    set_color normal
    set_color ff9e00
    echo "   Erneuern:  sshca      → Browser oeffnet Authelia, mit 2FA anmelden, fertig (7 Tage gueltig)"
    echo "   Erzwingen: sshca -f   · Pruefen: ssh-add -L | ssh-keygen -Lf - | grep Valid"
    echo "   Klappt nicht (Authelia/step-ca down)? Notzugang siehe Vault: Homelab/SSH-Zertifikate"
    set_color normal
    echo
end

__sshca_pruefen
functions -e __sshca_pruefen
