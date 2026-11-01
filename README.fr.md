[🇬🇧 Read in English](README.md)

# scandoc.sh — Assistant scanner pour Linux

Script Bash pour scanner des documents via SANE, les traiter avec ImageMagick et les exporter en PDF compressé ou en JPEG. Conçu pour être simple à utiliser au quotidien, avec un mode interactif guidé et un mode ligne de commande pour l'automatisation.

---

## Fonctionnalités

- **Mode interactif** — menus guidés étape par étape, aucune connaissance technique requise
- **Mode CLI** — toutes les options disponibles en ligne de commande pour l'automatisation
- **4 modes de traitement image** — nettoyage fond gris, noir et blanc pur, normalisation couleur, brut
- **Formats papier** — A4, A5, Letter, Legal, personnalisé, ou détection automatique avec recadrage
- **Résolution configurable** — 150 / 300 / 600 dpi ou valeur libre
- **Scan multi-pages** — nombre fixe, mode continu (page par page jusqu'à arrêt manuel) ou chargeur automatique (ADF)
- **Sortie PDF ou JPEG**
- **Compression PDF** — via Ghostscript (preset automatique selon la résolution) ; en noir et blanc, compression CCITT Group4 sans perte, beaucoup plus légère
- **OCR** — texte sélectionnable et copiable dans le PDF via ocrmypdf + Tesseract
- **Suppression des métadonnées** — tout supprimer ou tout sauf les dates, pour PDF et JPEG
- **Installation automatique des dépendances** manquantes en mode interactif
- **Traitement d'un fichier existant** — bypass du scan, traitement d'une image ou d'un PDF déjà présent

---

## Dépendances

### Obligatoires

```bash
sudo apt install sane-utils imagemagick ghostscript
```

| Paquet | Rôle |
|---|---|
| `sane-utils` | Interface avec le scanner (`scanimage`) |
| `imagemagick` | Traitement d'image, conversion, assemblage PDF |
| `ghostscript` | Compression et optimisation PDF |

### Optionnelles

```bash
sudo apt install ocrmypdf tesseract-ocr-fra   # OCR français
sudo apt install libimage-exiftool-perl qpdf   # Suppression complète et définitive des métadonnées
```

| Paquet | Rôle |
|---|---|
| `ocrmypdf` | Ajoute une couche de texte invisible dans le PDF |
| `tesseract-ocr-fra` | Données de langue française pour Tesseract (OCR) |
| `libimage-exiftool-perl` | Supprime les résidus de métadonnées laissés par Ghostscript |
| `qpdf` | Réécrit le PDF pour que les métadonnées supprimées ne soient plus récupérables |

> En mode interactif, le script propose d'installer automatiquement les paquets manquants.

---

## Installation

```bash
git clone <url-du-repo>
cd "Scan document linux"
chmod +x scandoc.sh
```

Optionnel — rendre accessible depuis n'importe où :

```bash
sudo ln -s "$PWD/scandoc.sh" /usr/local/bin/scandoc
```

---

## Utilisation

### Mode interactif (recommandé)

```bash
./scandoc.sh
```

Le script guide étape par étape :

1. Choix de l'action (scan simple / fichier existant / multi-pages / diagnostic des scanners)
2. Sélection du scanner (auto-détection, choix dans la liste ou saisie manuelle)
3. Format papier
4. Résolution
5. Mode de traitement
6. Format de sortie (PDF ou JPEG) et nom du fichier
7. OCR (PDF uniquement)
8. Métadonnées
9. Options avancées (compression, seuils, qualité JPEG…)
10. Récapitulatif et confirmation

### Mode ligne de commande

```bash
./scandoc.sh [OPTIONS]
```

---

## Options CLI

| Option | Description | Défaut |
|---|---|---|
| `-r <dpi>` | Résolution (150 / 300 / 600 ou libre) | `300` |
| `-m <mode>` | Mode de traitement (`scan` / `clean` / `bw` / `color`) | `clean` |
| `-o <fichier>` | Fichier de sortie | `scan_YYYYMMDD_HHMMSS.pdf` |
| `-f <fichier>` | Fichier source existant (bypass le scan) | — |
| `-F <format>` | Format papier : `auto`, `A4`, `A5`, `Letter`, `Legal`, `WxH` (mm) | `auto` |
| `-O <format>` | Format de sortie : `pdf` ou `jpeg` | `pdf` |
| `-d <device>` | Identifiant SANE du scanner | auto-détection |
| `-p` | Mode multi-pages | — |
| `-n <nb>` | Nombre de pages (active le mode multi-pages si > 1) | `1` |
| `-a` | Chargeur automatique (ADF) : scanne tout le bac d'un coup | — |
| `-2`, `--recto-verso` | Recto verso avec le chargeur : les deux faces de chaque feuille deviennent des pages (implique `-a`) | — |
| `-S <source>` | Source SANE explicite (`ADF`, `ADF Duplex`, `Flatbed`…, voir `scanimage -A`) | auto-détectée avec `-a` |
| `-R` | Activer l'OCR | — |
| `-L <lang>` | Langue OCR (`fra`, `eng`, `fra+eng`…) | `fra+eng` |
| `-M` | Supprimer toutes les métadonnées | — |
| `-t <0-100>` | Seuil de binarisation (mode `bw`) | `55` |
| `-w <0-100>` | Seuil de blanchiment (mode `clean`) | `75` |
| `-b <0-3>` | Flou anti-bruit avant binarisation | `0` |
| `-C` | Désactiver la compression Ghostscript | — |
| `-y` | Écraser le fichier de sortie s'il existe déjà (sinon : question, ou erreur hors terminal) | — |
| `-V` | Ouvrir le fichier produit à la fin (`xdg-open`) | — |
| `-k` | Garder les fichiers temporaires (debug) | — |
| `-l` | Lister les scanners disponibles | — |
| `-D`, `--diagnostic` | Afficher ce que chaque scanner accepte (sources, modes, résolutions, zone) | — |
| `-h` | Afficher l'aide | — |

---

## Réglages par défaut

Le menu **« Réglages par défaut »** (choix 5 du menu principal) enregistre vos choix habituels dans `~/.config/scandoc.conf` (ou `$XDG_CONFIG_HOME/scandoc.conf`, ou le chemin de la variable `SCANDOC_CONFIG`). Ils sont ensuite proposés par défaut dans les menus et utilisés en ligne de commande ; les options de la ligne de commande restent prioritaires.

Le fichier peut aussi s'écrire à la main, une clé par ligne (il n'est jamais exécuté) :

```ini
DEVICE="brother5:net1;dev0"
RESOLUTION="300"
MODE="clean"            # scan | clean | bw | color
PAPER_FORMAT="A4"       # auto | A4 | A5 | Letter | Legal | 210x297
OUTPUT_FORMAT="pdf"     # pdf | jpeg
OUTPUT_DIR="~/Documents/Scans"   # où ranger un fichier nommé sans dossier
OCR="true"
OCR_LANG="fra"
STRIP_META="all"        # all | nodates | false
OPEN_RESULT="true"      # ouvrir le fichier à la fin
```

Autres clés possibles : `SCAN_SOURCE`, `JPEG_QUALITY`, `THRESHOLD`, `WHITE_THRESH`, `BLUR`, `COMPRESS`.

En mode interactif, les chemins acceptent `~` et le glisser-déposer depuis le gestionnaire de fichiers (guillemets, `file://`).

---

## Exemples

```bash
# Scan simple, paramètres par défaut
./scandoc.sh -o facture.pdf

# Scan haute résolution en couleur
./scandoc.sh -r 600 -m color -o photo.pdf

# Traiter un fichier existant en noir et blanc
./scandoc.sh -f scan_brut.jpg -m bw -t 60 -o resultat.pdf

# Scan 5 pages assemblées en un seul PDF
./scandoc.sh -p -n 5 -o dossier.pdf

# Toutes les pages du chargeur automatique, en noir et blanc
./scandoc.sh -a -m bw -o courrier.pdf
./scandoc.sh --recto-verso -o recto_verso.pdf

# PDF avec OCR en français + suppression des métadonnées
./scandoc.sh -R -L fra -M -o document_ocr.pdf

# Format A4 explicite, compression désactivée
./scandoc.sh -F A4 -C -o original.pdf

# Lister les scanners disponibles
./scandoc.sh -l
```

---

## Modes de traitement

| Mode | Usage | Description |
|---|---|---|
| `clean` | Lettres, factures, contrats | Blanchit le fond gris, préserve les couleurs |
| `bw` | Formulaires, reçus, texte simple | Noir et blanc pur, fichier très léger |
| `color` | Photos, plans, documents colorés | Normalisation et boost des couleurs |
| `scan` | Archivage brut | Aucun traitement, PDF direct du scanner |

---

## OCR — Texte sélectionnable

Lorsque l'OCR est activé, le PDF final contient une couche de texte invisible superposée à l'image. Le texte devient :
- copiable-collable
- cherchable avec Ctrl+F
- lisible par les lecteurs d'écran

Le traitement est non-destructif : `--skip-text` évite de retraiter les pages qui ont déjà du texte. En cas d'échec de l'OCR, le PDF image est conservé sans erreur fatale.

**Langues disponibles** (codes ISO 639-2) : `fra`, `eng`, `deu`, `spa`, `ita`… Plusieurs langues séparées par `+` : `fra+eng`.

Pour installer une langue supplémentaire :
```bash
sudo apt install tesseract-ocr-<code>   # ex: tesseract-ocr-deu
```

---

## Métadonnées

Les PDF et JPEG produits contiennent par défaut des métadonnées révélant les outils utilisés (ImageMagick, Ghostscript, OCRmyPDF…). Trois options disponibles :

| Mode | Comportement |
|---|---|
| **Conserver** *(défaut)* | Métadonnées d'origine préservées |
| **Supprimer sauf les dates** | Vide les champs outil/auteur, conserve CreationDate et ModDate |
| **Supprimer tout** | Aucune métadonnée |

> **Note PDF** : Ghostscript réinjecte toujours son champ `Producer`, et exiftool modifie les PDF de façon réversible (les anciennes valeurs restent dans le fichier). Installez `libimage-exiftool-perl` et `qpdf` : exiftool vide les champs, puis qpdf réécrit le fichier pour que rien ne soit récupérable.

---

## Compatibilité scanner

Le script passe par SANE (`scanimage`) : il marche avec tous les scanners pris en charge par SANE sous Linux (Brother, Epson, Canon, HP, Fujitsu, Plustek…), y compris la plupart des scanners réseau ou récents sans pilote grâce à [`sane-airscan`](https://github.com/alexpevzner/sane-airscan) (`sudo apt install sane-airscan`).

Chaque pilote nomme ses réglages à sa façon. Avant de scanner, le script lit une fois les options du scanner (`scanimage -A`) et s'adapte :

- **Mode couleur** : le nom attendu par le pilote est choisi automatiquement (`Color`, `Colour`, `24bit Color`… / `Gray`, `Grayscale`, `True Gray`…).
- **Résolution** : arrondie à la valeur acceptée la plus proche (ex. 250 dpi → 300 dpi si le scanner ne propose que 200 et 300).
- **Format papier** : limité à la zone maximale du scanner (ex. Legal sur une vitre A4).
- **Chargeur (`-a`)** : la source « ADF » / « Feeder » est trouvée parmi celles du scanner.
- **Recto verso (`-2`)** : la source recto verso du chargeur (`Duplex ADF`, `ADF Duplex`…) est choisie automatiquement ; en mode interactif, la question est posée dans le menu du chargeur. Sans source recto verso, seul le recto est scanné (avec un avertissement).
- **Scanner sans vitre (à défilement)** : un scan simple utilise le chargeur en recto seul.
- **Plusieurs scanners** : en mode interactif, le script demande lequel utiliser ; en ligne de commande, il prend le premier et indique comment choisir les autres avec `-d`. Les webcams sont ignorées.

Chaque ajustement est signalé par un avertissement. Si les options du scanner ne peuvent pas être lues, les réglages standard (`Color`/`Gray`) sont utilisés.

Pour voir les scanners détectés et ce que chacun accepte :
```bash
./scandoc.sh -l            # liste rapide
./scandoc.sh --diagnostic  # détail : sources, modes, résolutions, zone maximale
```

Les pilotes propriétaires de certains fabricants (Brother `brscan`, Epson Image Scan…) sont à installer séparément, depuis le site du fabricant.

Backends testés : `dsseries` (Brother DS-720D).

---

## Licence

MIT
