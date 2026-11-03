# Stop Stutter sur macOS 12 (Monterey) — notes du backport

> **État : non compilé, non testé.** Ce port a été écrit sans Mac, sans Xcode et sans compilateur Swift.
> Le code a été relu et vérifié statiquement (délimiteurs équilibrés, API plus récentes que macOS 12 retirées),
> mais la première compilation peut afficher des erreurs à corriger, et rien n'a tourné sur un vrai macOS 12.

## Obtenir le .dmg

### Option A — GitHub Actions (aucun Mac ni Xcode nécessaire)

1. Crée un dépôt GitHub (privé, c'est très bien) et pousse ce dossier dedans.
2. Onglet **Actions** → **Build macOS 12 DMG** → **Run workflow**.
3. Quand le job est vert, télécharge l'artefact `StopStutter-macOS12-dmg` : il contient le `.dmg`.

Le workflow signe avec un certificat auto-signé jetable. Si le runner `macos-26` n'est pas disponible pour ton
compte, remplace `runs-on` par `macos-15` dans `.github/workflows/macos12-dmg.yml`.

### Option B — sur un Mac

Il faut Xcode 14.2 (le dernier qui tourne sur macOS 12.5) ou plus récent, et une identité de signature :

- un certificat **Apple Development** ou **Developer ID**, ou
- un certificat **auto-signé** : Trousseau d'accès → Assistant de certification → *Créer un certificat…* → nom
  `Stop Stutter Local`, type d'identité *Racine auto-signée*, type de certificat *Signature de code*.

```sh
UNIVERSAL=1 SIGNING_IDENTITY="Stop Stutter Local" ./scripts/build.sh
SIGNING_IDENTITY="Stop Stutter Local" ./scripts/make-dmg.sh
```

Le disque est écrit dans `dist/`. Sans identité (signature ad-hoc, `-`), l'app s'ouvre mais l'assistant
privilégié refuse volontairement de s'installer : les deux côtés se vérifient par signature de code.

## Installer

1. Ouvre le `.dmg` et glisse l'app dans **Applications** (obligatoire pour activer l'assistant).
2. Premier lancement : clic droit → **Ouvrir** (l'app n'est pas notarisée).
3. **Enable Helper** → macOS demande ton mot de passe administrateur une fois.

## Ce qui change par rapport à la version macOS 14+

| Sujet | Version d'origine | Backport macOS 12 |
|---|---|---|
| Installation de l'assistant | `SMAppService` (macOS 13+) | copie dans `/Library/PrivilegedHelperTools`, plist dans `/Library/LaunchDaemons`, `launchctl bootstrap`, un mot de passe admin |
| Vérification XPC | `setCodeSigningRequirement` (macOS 13+) | vérifications `SecCode` à la main des deux côtés ; macOS 13+ garde l'API native |
| Identité de signature | ID d'équipe Apple obligatoire | ID d'équipe, ou certificat auto-signé épinglé par son empreinte |
| Fenêtre / barre de menus | `Window`, `MenuBarExtra` (macOS 13+) | `NSWindow` + `NSStatusItem` + `NSPopover` |
| Lancement à l'ouverture de session | `SMAppService.mainApp` | LaunchAgent dans `~/Library/LaunchAgents` |
| Liquid Glass | macOS 26+ | retiré, matériaux natifs |
| Divers | `Text.tracking`, `Button(_:systemImage:)`, `ContentUnavailableView`, `Task.sleep(for:)` | équivalents macOS 12 |

## Limites et points à vérifier au premier essai

- Sur macOS 12, la vérification de l'app par l'assistant lit le jeton d'audit du `NSXPCConnection` (propriété non
  documentée mais stable). Si elle est introuvable, le code retombe sur le PID, ce qui vérifie toujours la
  signature mais sans protection contre la réutilisation de PID.
- Le popover de la barre de menus et l'habillage de la fenêtre (barre de titre transparente) n'ont pas été
  vérifiés visuellement.
- Le changement d'état de `awdl0` suppose le même comportement que `ifconfig awdl0 down` sur Monterey.
- Après une mise à jour de l'app, Réglages propose **Update Helper** : l'assistant installé n'est plus remplacé
  automatiquement.

## Dépannage

```sh
# Journal de l'assistant
log show --predicate 'subsystem == "io.github.burakgon.StopStutter.Helper"' --last 10m

# Retirer l'assistant à la main
sudo launchctl bootout system/io.github.burakgon.StopStutter.Helper
sudo rm /Library/LaunchDaemons/io.github.burakgon.StopStutter.Helper.plist \
        /Library/PrivilegedHelperTools/io.github.burakgon.StopStutter.Helper

# Rétablir AWDL si besoin
sudo ifconfig awdl0 up
```

Sans l'app, l'effet est le même à la main : `sudo ifconfig awdl0 down` avant de jouer, `up` après.
