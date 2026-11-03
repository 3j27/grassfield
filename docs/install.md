# Install Grassfield / Installer Grassfield

DRAFT (ADR-0043). Not published: the host, the key fingerprint and the checksum below are placeholders until the owner chooses
the hosting (O8) and provides the signing key (O11), and the legal review is done. Brouillon : rien n'est publié.

---

## English

Grassfield is a desktop session for **Omarchy 4.0.6 or newer** (Arch Linux, x86_64). Installing it does not remove Omarchy: you
choose which one starts at login, and you can go back at any time.

### Before you start
- A working Omarchy 4.0.6+, up to date (run Omarchy's own update first), with about 4 GiB free.
- An administrator account (the script asks for your password with `sudo`).
- Omarchy's snapshots are used if they are set up: the script takes one before it changes anything.

### Install
Open a terminal in Omarchy and run these three commands. Do not use `sudo` yourself.
```bash
curl -fsSLO https://HOST.PLACEHOLDER/install/grassfield-install.sh
curl -fsSLO https://HOST.PLACEHOLDER/install/grassfield-install.sh.sha256
sha256sum -c grassfield-install.sh.sha256 && bash grassfield-install.sh
```
- The second command downloads the checksum; the third checks the script against it and runs it only if it matches.
  The checksum is also published at: SITE.PLACEHOLDER and README.PLACEHOLDER (it must be the same everywhere):
  `SHA256: CHECKSUM.PLACEHOLDER`.
- The script checks your system first and prints what is wrong with the exact fix, without changing anything.
- It then shows a **plan** of everything it will change and asks you to confirm. `--dry-run` shows the plan and stops;
  `--yes` skips the question; `--channel beta` follows the beta channel; `--help` lists the options.
- Everything it does is logged to `~/.local/state/grassfield/install.log`.

The signing key of the packages is pinned in the script: fingerprint `FINGERPRINT.PLACEHOLDER`. You can compare it with the
one on the site. Packages are only installed if they are signed by that key.

### What it changes
1. A snapshot (if Omarchy's snapshots are set up).
2. Trusts Grassfield's signing key in pacman (`pacman-key`, with that exact fingerprint).
3. Adds the `[grassfield]` repository: `/etc/pacman.d/grassfield.conf` and two lines at the end of `/etc/pacman.conf`
   (a copy is kept next to it as `pacman.conf.grassfield-install-bak`).
4. Installs `grassfield-desktop`, `grassfield-compositor` and `grassfield-store` with their dependencies.
5. Hands the repository over to `grassfield-channel-set`, which keeps it working across Omarchy updates.
6. Makes Grassfield the session of your next login (`grassfield-login set grassfield`; use `--session omarchy` to keep Omarchy).

It never reorders your repositories and never touches Omarchy's files.

### After the install
Restart the computer once. At the login screen choose **Grassfield (uwsm)** (it is the default). Updates then arrive from
Settings > Software Update.

### Go back to Omarchy
- Only for the next login: `grassfield-login set omarchy`, then log out.
- Remove Grassfield completely: run the script again with `--uninstall`. It takes a snapshot, turns Grassfield updates off,
  switches the session back to Omarchy, removes the packages, the `[grassfield]` repository and the key. Restart once.

Run it again at any time with the same command to repair or update: it never duplicates anything.

---

## Français

Grassfield est une session de bureau pour **Omarchy 4.0.6 ou plus récent** (Arch Linux, x86_64). L'installer ne supprime pas
Omarchy : tu choisis ce qui démarre à la connexion et tu peux revenir en arrière à tout moment.

### Avant de commencer
- Un Omarchy 4.0.6+ qui fonctionne, à jour (lance d'abord la mise à jour d'Omarchy), avec environ 4 Gio libres.
- Un compte administrateur (le script demande ton mot de passe via `sudo`).
- Les snapshots d'Omarchy sont utilisés s'ils sont configurés : le script en prend un avant toute modification.

### Installer
Ouvre un terminal dans Omarchy et lance ces trois commandes. N'utilise pas `sudo` toi-même.
```bash
curl -fsSLO https://HOST.PLACEHOLDER/install/grassfield-install.sh
curl -fsSLO https://HOST.PLACEHOLDER/install/grassfield-install.sh.sha256
sha256sum -c grassfield-install.sh.sha256 && bash grassfield-install.sh
```
- La deuxième commande télécharge la somme de contrôle ; la troisième vérifie le script avec elle et ne le lance que si elle
  correspond. La somme est aussi publiée sur : SITE.PLACEHOLDER et README.PLACEHOLDER (elle doit être identique partout) :
  `SHA256: CHECKSUM.PLACEHOLDER`.
- Le script vérifie d'abord ton système et affiche ce qui ne va pas avec le correctif exact, sans rien modifier.
- Il affiche ensuite un **plan** de tout ce qu'il va changer et te demande de confirmer. `--dry-run` montre le plan et
  s'arrête ; `--yes` supprime la question ; `--channel beta` suit le canal bêta ; `--help` liste les options.
- Tout ce qu'il fait est écrit dans `~/.local/state/grassfield/install.log`.

La clé de signature des paquets est fixée dans le script : empreinte `FINGERPRINT.PLACEHOLDER`. Tu peux la comparer avec celle
du site. Les paquets ne sont installés que s'ils sont signés par cette clé.

### Ce qu'il modifie
1. Un snapshot (si les snapshots d'Omarchy sont configurés).
2. Fait confiance à la clé de signature de Grassfield dans pacman (`pacman-key`, avec cette empreinte exacte).
3. Ajoute le dépôt `[grassfield]` : `/etc/pacman.d/grassfield.conf` et deux lignes à la fin de `/etc/pacman.conf` (une copie
   reste à côté : `pacman.conf.grassfield-install-bak`).
4. Installe `grassfield-desktop`, `grassfield-compositor` et `grassfield-store` avec leurs dépendances.
5. Confie le dépôt à `grassfield-channel-set`, qui le maintient à travers les mises à jour d'Omarchy.
6. Fait de Grassfield la session de ta prochaine connexion (`grassfield-login set grassfield` ; `--session omarchy` pour garder
   Omarchy).

Il ne réordonne jamais tes dépôts et ne touche jamais aux fichiers d'Omarchy.

### Après l'installation
Redémarre l'ordinateur une fois. À l'écran de connexion choisis **Grassfield (uwsm)** (c'est le choix par défaut). Les mises à
jour arrivent ensuite depuis Réglages > Mise à jour.

### Revenir à Omarchy
- Seulement pour la prochaine connexion : `grassfield-login set omarchy`, puis ferme la session.
- Retirer Grassfield complètement : relance le script avec `--uninstall`. Il prend un snapshot, désactive les mises à jour
  Grassfield, remet la session sur Omarchy, retire les paquets, le dépôt `[grassfield]` et la clé. Redémarre une fois.

Relance la même commande à tout moment pour réparer ou mettre à jour : rien n'est jamais dupliqué.
