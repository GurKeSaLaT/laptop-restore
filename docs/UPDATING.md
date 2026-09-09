# Repo aktuell halten

Dieses Repo bildet einen Zustand ab, keinen Automatismus, der von allein
mitzieht. Wenn du auf dem Laptop etwas neu konfigurierst, musst du es
bewusst zurück ins Repo holen. Zwei Skripte dafür:

## Pakete: `scripts/capture-packages.sh`

```bash
./scripts/capture-packages.sh
```

Liest `pacman -Qqe` / `pacman -Qqm` auf **diesem** Rechner und schreibt
`roles/packages/vars/main.yml` komplett neu. Sicher automatisierbar, weil
Paketnamen kein Geheimnis sind. Zeigt danach `git diff` — passt es,
committen + pushen.

## $HOME-Configs: `scripts/capture-config.sh`

```bash
./scripts/capture-config.sh ~/.config/foot/foot.ini ~/.config/fish/config.fish
```

Übernimmt genau die angegebenen Pfade 1:1 nach `roles/user_config/files/`
(gleiche relative Struktur), die dann bei jedem Restore automatisch mit
deployed werden. **Bewusst kein automatischer `~/.config`-Vollsync** — dafür
zwei Gründe:

1. **Secrets-Risiko.** `~/.config` sammelt bei praktisch jedem System
   irgendwann Session-Tokens, API-Keys o.ä. an (Browser, Discord, diverse
   CLI-Tools). Ein Vollsync würde das früher oder später ungeprüft ins Repo
   ziehen — der Sinn der ganzen ansible-vault-Übung wäre dahin.
   `capture-config.sh` warnt zwar heuristisch (`password=`, `token:`,
   `PRIVATE KEY`, …), aber die bewusste Auswahl ist die eigentliche
   Absicherung.

2. **end-4/dots-hyprland-Dateien sind in zwei Kategorien gesplittet:**
   - **Automatisch aktualisierte Dateien** — kommen mit jedem
     `update-dotfiles`/`./setup install` frisch aus dem Repo
     (`github.com/end-4/dots-hyprland`), das übernimmt schon
     `roles/dotfiles`. Diese **nicht** mit `capture-config.sh` erfassen —
     würde nur den öffentlichen Upstream-Stand einfrieren und beim
     nächsten echten Update wieder überschrieben.
   - **Custom/User-Dateien** — von dir bewusst angepasste Werte
     (z. B. `~/.config/hypr/hyprland/general.lua` mit `kb_layout`, Gaps,
     Animationen — das ist bereits fest in `roles/hyprland` eingebaut).
     Woran du die zweite Kategorie erkennst: `./setup install`
     überschreibt eine von dir geänderte, eigentlich verwaltete Datei
     nicht direkt, sondern legt eine `*.conf.new`-Datei daneben (siehe
     `~/config/arch-zfs-safe-updates.md`). Taucht nach einem
     Dotfiles-Update nirgendwo ein `*.new` auf: dann ist es wahrscheinlich
     ohnehin schon eine reine Custom-Datei außerhalb der verwalteten
     Struktur. Diese Kategorie **gehört** erfasst.
   - Alles, was **gar nicht** Teil von `dots-hyprland` ist (fish-Config,
     Terminal-Emulator-Settings, eigene Skripte außerhalb von
     `/usr/local/bin`, …), gehört ebenfalls hierher.

Faustregel: **"Käme das nach `update-dotfiles` von allein wieder, so wie
es ist?"** Ja → nicht erfassen (schon durch `roles/dotfiles` abgedeckt).
Nein, das ist mein eigener Stand → `capture-config.sh` drauf ansetzen.

## Ablauf nach Änderungen

```bash
cd ~/laptop-restore   # oder wo auch immer das Repo liegt
./scripts/capture-packages.sh     # falls Pakete sich geändert haben
./scripts/capture-config.sh ~/.config/irgendwas
git add -A
git commit -m "..."
git push
```

Der Pre-Commit-Hook (`scripts/git-hooks/pre-commit`) prüft dabei weiterhin,
dass `vault.yml` verschlüsselt bleibt — betrifft dieses Update-Vorgehen
nicht direkt, greift aber trotzdem als Sicherheitsnetz, falls du versehentlich
Secrets in eine erfasste Config-Datei mit reinkopierst.
