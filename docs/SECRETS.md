# Secrets-Handling

## Warum nicht GitHub Secrets?

GitHub Actions/Codespaces-Secrets werden ausschließlich **innerhalb eines auf
GitHub laufenden Jobs** in Umgebungsvariablen injiziert. Ein `git clone`
eines Live-Systems ist kein GitHub-Job — es bekommt diese Werte nie zu
sehen. GitHub-Secrets lösen ein anderes Problem (CI-Pipelines), nicht
"Secrets lokal auf einem frisch gebooteten Rechner entschlüsseln".

## Der gewählte Ansatz: ansible-vault

- Alle Geheimnisse leben in `group_vars/all/vault.yml`, **verschlüsselt**
  mit `ansible-vault`. Der Chiffretext ist git-versioniert und darf
  öffentlich sein (ist es hier ohnehin nicht, Repo ist privat) — er ist ohne
  Passwort wertlos.
- Das Vault-**Passwort** selbst ist der einzige verbleibende Single Point of
  Failure und liegt **nie** im Repo.

## Wo das Vault-Passwort aufbewahren?

Drei gängige Optionen, wähl eine (oder kombiniere):

1. **Nur im Kopf / Passwort-Manager, manuell eingeben.**
   `ansible-playbook site.yml --ask-vault-pass` fragt interaktiv danach.
   Kein zusätzliches Tooling, funktioniert auch offline im Live-System.

2. **Separater USB-Stick**, den du getrennt vom Laptop aufbewahrst — genau
   für den Fall gedacht, dass beides (Laptop *und* GitHub-Zugang) gleichzeitig
   weg sind. Eine Datei mit dem Passwort drauf, referenziert per
   `--vault-password-file /media/usb/vault-pass.txt` (bei
   `scripts/00-disk-and-base-install.sh` kurz `-f /media/usb/vault-pass.txt`).

3. **Passwort-Manager-CLI** (Bitwarden `bw`, 1Password `op`, …), verpackt in
   ein kleines ausführbares Skript, das den Wert auf stdout ausgibt:
   ```bash
   #!/usr/bin/env bash
   bw unlock --check >/dev/null || bw unlock
   bw get password laptop-restore-ansible-vault
   ```
   Dann: `ansible-playbook site.yml --vault-password-file ./scripts/bw-vault-pass.sh`
   Setzt voraus, dass du im Live-System Zugriff auf den Passwort-Manager
   hast (Web-Vault reicht, Live-ISO hat i.d.R. einen Browser oder zumindest
   `curl` für die API).

**Wichtig in jedem Fall:** Das Vault-Passwort darf niemals in dieselbe
Kette wie "GitHub-Zugang" fallen (z. B. nicht im selben, per SSH-Key
geschützten GitHub-Account gespeichert sein, den du gerade zum Klonen
brauchst) — sonst hast du effektiv wieder ein Secret neben dem Repo liegen,
nur einen Schritt versteckter.

## Neue Secrets hinzufügen

```bash
ansible-vault edit group_vars/all/vault.yml
```
Öffnet die Datei entschlüsselt in `$EDITOR`, verschlüsselt sie beim
Speichern automatisch wieder. Nie `vim group_vars/all/vault.yml` direkt
benutzen (das würde den Klartext auf Platte schreiben, bis du selbst wieder
`ansible-vault encrypt` aufrufst) — der Pre-Commit-Hook fängt das zwar vorm
Commit ab, aber besser gar nicht erst riskieren.

## Vault-Passwort rotieren

```bash
ansible-vault rekey group_vars/all/vault.yml
```
