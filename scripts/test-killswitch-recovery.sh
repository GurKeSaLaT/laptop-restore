#!/bin/bash
# Regressionstest (2026-10-22): Der Killswitch darf nach EINEM fehlgeschlagenen DoH-Lauf nicht im STRICT-Regelwerk haengen bleiben.
# Fehlerbild: bestehende Verbindungen laufen, neue nicht, Anzeige steht auf HOME. Ursache: Modus-Datei blieb auf HOME, naechster Lauf lud nichts neu.
# Aufruf: repro.sh [Pfad-zum-Skript]   Exit 0 = gruen (Regelwerk erholt sich), 1 = rot (haengt in STRICT)
set -u
SRC="${1:-/usr/local/sbin/vpn-killswitch-apply}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"
sed -e "s#/run/#$T/run/#g" "$SRC" > "$T/ks"; chmod +x "$T/ks"
cat > "$T/bin/curl" <<'S'
#!/bin/bash
a="$*"
case "$a" in
  *dns-query*) [ -e "$T/doh_ok" ] && echo '{"Answer":[{"data":"87.1.1.1"}]}' ;;
  *ipify*|*icanhazip*) [ -e "$T/ip_ok" ] && echo 87.1.1.1 ;;
esac; exit 0
S
cat > "$T/bin/nft" <<'S'
#!/bin/bash
in=$(cat); if echo "$in" | grep -q "policy drop"; then echo STRICT > "$T/applied"; else echo HOME > "$T/applied"; fi
S
cat > "$T/bin/ip" <<'S'
#!/bin/bash
echo "default via 192.168.10.1 dev wlp108s0 proto dhcp"
S
printf '#!/bin/bash\necho full\n' > "$T/bin/nmcli"
printf '#!/bin/bash\nexit 3\n' > "$T/bin/systemctl"
printf '#!/bin/bash\necho "$*" >> "$T/log"\n' > "$T/bin/logger"
printf '#!/bin/bash\necho 87.1.1.1 STREAM host\n' > "$T/bin/getent"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/ping"
chmod +x "$T"/bin/*; export T PATH="$T/bin:$PATH"
run() { "$T/ks" >/dev/null 2>&1; echo "  Lauf $1: Modus-Datei=$(cat "$T/run/vpn-killswitch-state" 2>/dev/null || echo -) | aktives Regelwerk=$(cat "$T/applied" 2>/dev/null || echo -)"; }
touch "$T/doh_ok" "$T/ip_ok"
echo "1) alles ok";                           run 1
rm "$T/doh_ok"
echo "2) DoH-Abfrage faellt EINMAL aus";      run 2
touch "$T/doh_ok"
echo "3) alles wieder ok (20 s spaeter)";     run 3
echo "4) noch ein Lauf";                      run 4
want=HOME; got=$(cat "$T/applied")
[ "$got" = "$want" ] && { echo "GRUEN: Regelwerk ist wieder $want"; exit 0; } || { echo "ROT: Regelwerk bleibt $got, obwohl alles wieder ok ist"; exit 1; }
