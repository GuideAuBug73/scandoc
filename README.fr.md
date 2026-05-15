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
- **Scan multi-pages** — nombre fixe ou mode continu (page par page jusqu'à arrêt manuel)
- **Sortie PDF ou JPEG**
- **Compression PDF** — via Ghostscript (preset automatique selon la résolution)
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
sudo apt install libimage-exiftool-perl        # Suppression complète des métadonnées
```

| Paquet | Rôle |
|---|---|
| `ocrmypdf` | Ajoute une couche de texte invisible dans le PDF |
| `tesseract-ocr-fra` | Données de langue française pour Tesseract (OCR) |
| `libimage-exiftool-perl` | Supprime les résidus de métadonnées laissés par Ghostscript |

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

1. Choix de l'action (scan simple / fichier existant / multi-pages / lister les scanners)
2. Sélection du scanner (auto-détection ou saisie manuelle)
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
| `-n <nb>` | Nombre de pages (mode multi-pages) | `1` |
| `-R` | Activer l'OCR | — |
| `-L <lang>` | Langue OCR (`fra`, `eng`, `fra+eng`…) | `fra+eng` |
| `-M` | Supprimer toutes les métadonnées | — |
| `-t <0-100>` | Seuil de binarisation (mode `bw`) | `55` |
| `-w <0-100>` | Seuil de blanchiment (mode `clean`) | `75` |
| `-b <0-3>` | Flou anti-bruit avant binarisation | `0` |
| `-C` | Désactiver la compression Ghostscript | — |
| `-k` | Garder les fichiers temporaires (debug) | — |
| `-l` | Lister les scanners disponibles | — |
| `-h` | Afficher l'aide | — |

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

> **Note PDF** : Ghostscript réinjecte toujours son champ `Producer`. Installez `libimage-exiftool-perl` pour une suppression complète.

---

## Compatibilité scanner

Le script utilise SANE (`scanimage`) et est compatible avec tous les scanners supportés par SANE sous Linux : Brother, Epson, Canon, HP, Fujitsu, Plustek, etc.

Pour trouver l'identifiant de votre scanner :
```bash
./scandoc.sh -l
# ou
scanimage -L
```

Les backends testés : `dsseries` (Brother DS-720D). Les options utilisées (`--mode`, `--resolution`, `-x`, `-y`, `--format=pnm`) sont standard et supportées par la quasi-totalité des backends modernes.

---

## Licence

MIT
