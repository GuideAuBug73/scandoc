#!/usr/bin/env bash
# =============================================================================
#  scan-doc.sh — Scanner et nettoyer des documents vers PDF propre
# =============================================================================
#
#  DÉPENDANCES :
#    sudo apt install sane-utils imagemagick ghostscript
#
#  USAGE :
#    ./scan-doc.sh               # Mode interactif avec menus guidés (recommandé)
#    ./scan-doc.sh [OPTIONS]     # Mode ligne de commande (voir -h)
#
#  EXEMPLES CLI :
#    ./scan-doc.sh -o facture.pdf
#    ./scan-doc.sh -r 600 -m color -o photo.pdf
#    ./scan-doc.sh -f /tmp/scan.jpg -m clean
#    ./scan-doc.sh -m bw -t 60
#    ./scan-doc.sh -p -n 3 -o dossier.pdf
#
# =============================================================================

set -euo pipefail

# --- Couleurs terminal -------------------------------------------------------
# Syntaxe $'…' : les séquences d'échappement sont interprétées dès l'affectation,
# ce qui permet de les utiliser aussi avec cat/printf (ex. : l'aide -h).
RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'; DIM=$'\033[2m'
BLUE=$'\033[0;34m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERR]${RESET}  $*" >&2; exit 1; }

# =============================================================================
#  PARAMÈTRES PAR DÉFAUT
# =============================================================================

RESOLUTION=300          # dpi — 150=rapide/léger, 300=standard, 600=haute qualité
MODE="clean"            # scan | clean | bw | color
PAPER_FORMAT="auto"      # Format papier : auto, A4, A5, Letter, Legal, custom
OUTPUT=""               # Fichier de sortie (auto-généré si vide)
INPUT_FILE=""           # Fichier source existant (bypass le scan)
THRESHOLD=55            # Seuil de binarisation pour le mode bw (0-100)
WHITE_THRESH=75         # Seuil de blanchiment pour le mode clean (0-100)
BLUR=0                  # Rayon de flou avant traitement (0=désactivé)
DEVICE=""               # Scanner SANE (auto-détecté si vide)
MULTI_PAGE=false        # Scan multi-pages avec pause entre chaque page
NB_PAGES=1              # Nombre de pages (mode multi-pages)
MULTI_PAGE_MODE="fixed" # Mode multi-pages : fixed (nombre connu) | auto (continu jusqu'à stop) | adf (chargeur)
SCAN_SOURCE=""          # Source SANE (ex : "ADF", "Flatbed") — auto-détectée en mode adf si vide
DUPLEX=false            # Recto verso avec le chargeur (-2 / --recto-verso)
KEEP_TEMP=false         # Garder les fichiers temporaires (debug)
COMPRESS=true           # Compresser le PDF final avec ghostscript
DESKEW=true             # Redresser les pages scannées de travers (-s pour désactiver)
DEPTH=8                 # Profondeur de couleur (8=standard, 16=haute fidélité)
OUTPUT_FORMAT="pdf"     # Format de sortie : pdf | jpeg
JPEG_QUALITY=85         # Qualité JPEG (1-100, 85=bon compromis qualité/taille)
PAGES=()                # Pages traitées, dans l'ordre (remplies avant la finalisation)
OCR=false               # Activer l'OCR (texte sélectionnable) avec ocrmypdf
OCR_LANG="fra+eng"      # Langue(s) OCR : fra, eng, deu, spa... (séparer par +)
STRIP_META=false        # Métadonnées : false | all (tout supprimer) | nodates (tout sauf dates)
SCAN_TMPDIR=""          # Répertoire temporaire de travail (global pour le trap EXIT)
OUTPUT_DIR=""           # Dossier où ranger les fichiers dont le nom est donné sans chemin
OPEN_RESULT=false       # Ouvrir le fichier produit à la fin (xdg-open / open)
FORCE=false             # Écraser un fichier existant sans demander (-y)
OVERWRITE_OK=false      # Écrasement déjà confirmé (mode interactif)
CONFIG_FILE="${SCANDOC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/scandoc.conf}"
INTERACTIVE=false       # true en mode interactif (menus) : on peut poser des questions
DIAGNOSTIC=false        # -D / --diagnostic : afficher les capacités des scanners et quitter
LIST_ONLY=false         # -l : lister les scanners et quitter

# Capacités du scanner, lues une fois avec « scanimage -A » (voir prepare_scanner)
SCANNER_CAPS=""         # Sortie de « scanimage -A » pour le scanner et la source choisis
CAPS_KEY=""             # « scanner|source » pour lesquels SCANNER_CAPS a été lu (cache)
CAPS_OK=false           # true si les options du scanner ont pu être lues
SCAN_MODE_NAME="Color"  # Valeur passée à --mode, dans le vocabulaire du pilote (vide : pas de --mode)
SCAN_RES_OPT=true       # false si le scanner n'a pas d'option --resolution
SCAN_SIZE_OPTS=()       # Options -x / -y, limitées à la zone maximale du scanner

# =============================================================================
#  VÉRIFICATION DES DÉPENDANCES
# =============================================================================

# Mode CLI : erreur directe si dépendance manquante
check_deps() {
  local missing=()
  command -v convert   &>/dev/null || missing+=("imagemagick")
  command -v identify  &>/dev/null || missing+=("imagemagick")
  if [[ -z "$INPUT_FILE" ]]; then command -v scanimage &>/dev/null || missing+=("sane-utils"); fi
  if $COMPRESS; then command -v gs &>/dev/null || missing+=("ghostscript"); fi
  if $OCR; then command -v ocrmypdf &>/dev/null || missing+=("ocrmypdf"); fi
  if $COMPRESS || { [[ "$STRIP_META" != "false" ]] && [[ "$OUTPUT_FORMAT" != "jpeg" ]]; }; then
    command -v gs &>/dev/null || missing+=("ghostscript")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    # Dédoublonnage (imagemagick et ghostscript peuvent être signalés deux fois)
    local uniq; uniq=$(printf '%s\n' "${missing[@]}" | awk '!seen[$0]++' | tr '\n' ' ')
    error "Dépendances manquantes : ${uniq% }\n  → sudo apt install ${uniq% }"
  fi

  if [[ "$STRIP_META" != "false" ]] && [[ "$OUTPUT_FORMAT" == "pdf" ]]; then
    local opt_missing; opt_missing=$(_missing_pdf_meta_tools)
    if [[ -n "$opt_missing" ]]; then
      warn "Suppression des métadonnées partielle sans : ${opt_missing}  (sudo apt install ${opt_missing})"
    fi
  fi
  if [[ "$STRIP_META" != "false" ]] && [[ "$OUTPUT_FORMAT" == "jpeg" ]] && ! command -v exiftool &>/dev/null; then
    warn "exiftool absent : les métadonnées JPEG seront conservées (sudo apt install libimage-exiftool-perl)."
  fi
}

# Mode interactif : propose l'installation automatique des paquets manquants
check_and_install_deps() {
  local missing=()
  command -v convert   &>/dev/null || missing+=("imagemagick")
  command -v scanimage &>/dev/null || missing+=("sane-utils")
  command -v gs        &>/dev/null || missing+=("ghostscript")
  # ocrmypdf est optionnel : proposé seulement si absent, pas bloquant

  # Dédoublonnage
  local unique_missing=()
  declare -A _seen
  for pkg in "${missing[@]}"; do
    if [[ -z "${_seen[$pkg]+x}" ]]; then unique_missing+=("$pkg"); _seen[$pkg]=1; fi
  done
  unset _seen

  if [[ ${#unique_missing[@]} -eq 0 ]]; then return; fi

  echo ""
  warn "Logiciels manquants détectés :"
  echo ""
  for pkg in "${unique_missing[@]}"; do
    case "$pkg" in
      imagemagick) printf "    ${BOLD}%-14s${RESET}  %s\n" "imagemagick" "Traitement d'images (filtres, conversion, assemblage PDF)" ;;
      sane-utils)  printf "    ${BOLD}%-14s${RESET}  %s\n" "sane-utils"  "Interface avec le scanner (commande scanimage)" ;;
      ghostscript) printf "    ${BOLD}%-14s${RESET}  %s\n" "ghostscript" "Compression et optimisation du PDF final" ;;
      ocrmypdf)    printf "    ${BOLD}%-14s${RESET}  %s\n" "ocrmypdf"    "OCR : rend le PDF consultable et le texte sélectionnable" ;;
    esac
  done
  echo ""
  echo -e "  Commande : ${BOLD}sudo apt install ${unique_missing[*]}${RESET}"
  echo ""
  echo -ne "  ${BOLD}→${RESET} Installer maintenant ? [O/n] : "
  read -r _ans
  if [[ "${_ans,,}" != "n" ]]; then
    sudo apt install -y "${unique_missing[@]}" || error "Échec de l'installation des dépendances."
    success "Dépendances installées avec succès."
  else
    error "Logiciels requis manquants — impossible de continuer."
  fi
}

# =============================================================================
#  HELPERS D'AFFICHAGE
# =============================================================================

banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║       scan-doc.sh  —  Assistant scanner      ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

section() {
  echo ""
  echo -e "  ${BOLD}${BLUE}▸ $1${RESET}"
  printf "  ${DIM}"
  printf '%.0s─' {1..46}
  echo -e "${RESET}"
  echo ""
}

# print_opt NUM LABEL DESC [is_default]
# Affiche une ligne de menu : [N] Libellé    Description  ★ recommandé
print_opt() {
  local num="$1" label="$2" desc="$3" is_default="${4:-false}"
  if [[ "$is_default" == "true" ]]; then
    printf "    ${BOLD}[%s]${RESET} %-28s ${DIM}%s${RESET}  ${GREEN}★ par défaut${RESET}\n" \
      "$num" "$label" "$desc"
  else
    printf "    ${BOLD}[%s]${RESET} %-28s ${DIM}%s${RESET}\n" "$num" "$label" "$desc"
  fi
}

# Invite texte libre avec valeur par défaut — résultat dans $REPLY
ask() {
  local prompt="$1" default="$2"
  echo -ne "  ${BOLD}→${RESET} $prompt ${DIM}[défaut : $default]${RESET} : "
  read -r REPLY
  if [[ -z "$REPLY" ]]; then REPLY="$default"; fi
  return 0
}

# Invite choix numérique avec validation — résultat dans $REPLY
ask_choice() {
  local prompt="$1" default="$2" max="$3"
  while true; do
    echo -ne "\n  ${BOLD}→${RESET} $prompt ${DIM}[défaut : $default]${RESET} : "
    read -r REPLY
    if [[ -z "$REPLY" ]]; then REPLY="$default"; fi
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -ge 1 ]] && [[ "$REPLY" -le "$max" ]]; then
      return
    fi
    warn "Choix invalide. Entrez un nombre entre 1 et $max."
  done
}

# Invite nombre entier borné, redemandé tant que la saisie est invalide — résultat dans $REPLY
ask_int() {
  local prompt="$1" default="$2" min="$3" max="$4"
  while true; do
    ask "$prompt" "$default"
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( 10#$REPLY >= min && 10#$REPLY <= max )); then
      REPLY=$(( 10#$REPLY ))
      return 0
    fi
    warn "Valeur invalide. Entrez un nombre entre $min et $max."
  done
}

# Nettoie un chemin saisi au clavier ou glissé-déposé depuis un gestionnaire de
# fichiers : espaces autour, guillemets '…' ou "…", URI file://… (avec %20),
# espaces échappés « \  », et ~ en début de chemin.
_clean_path() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  if [[ ${#p} -ge 2 ]] && [[ ( "$p" == \'*\' ) || ( "$p" == \"*\" ) ]]; then
    p="${p:1:${#p}-2}"
  fi
  if [[ "$p" == file://* ]]; then
    p="${p#file://}"
    p="${p#localhost}"
    p=$(printf '%b' "${p//%/\\x}")
  fi
  if [[ ! -e "$p" ]] && [[ "$p" == *\\* ]]; then
    p="${p//\\ / }"
  fi
  if [[ "$p" == "~" ]]; then
    p="$HOME"
  elif [[ "$p" == "~/"* ]]; then
    p="${HOME}/${p#"~/"}"
  fi
  printf '%s' "$p"
}

# Normalise un booléen de configuration (true/false, oui/non, 1/0, yes/no)
_to_bool() {
  case "${1,,}" in
    true|oui|o|yes|y|1) echo true ;;
    false|non|n|no|0|"") echo false ;;
    *) return 1 ;;
  esac
}

# Clés autorisées dans le fichier de configuration
CONFIG_KEYS=(DEVICE SCAN_SOURCE RESOLUTION MODE PAPER_FORMAT OUTPUT_FORMAT OUTPUT_DIR
             JPEG_QUALITY THRESHOLD WHITE_THRESH BLUR COMPRESS DESKEW OCR OCR_LANG STRIP_META OPEN_RESULT)

# Lit le fichier de configuration (CLÉ=valeur, une par ligne, # pour commenter).
# Le fichier n'est jamais exécuté : seules les clés connues sont lues.
load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local line key val n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$(( n + 1 ))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=(.*)$ ]]; then
      warn "Configuration ligne ${n} ignorée (format CLÉ=valeur attendu) : ${line}"
      continue
    fi
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" == \"*\" ]] && [[ ${#val} -ge 2 ]]; then
      val="${val:1:${#val}-2}"; val="${val//\\\"/\"}"; val="${val//\\\\/\\}"
    elif [[ "$val" == \'*\' ]] && [[ ${#val} -ge 2 ]]; then
      val="${val:1:${#val}-2}"
    fi
    if [[ ! " ${CONFIG_KEYS[*]} " == *" $key "* ]]; then
      warn "Configuration ligne ${n} : clé inconnue « ${key} », ignorée."
      continue
    fi
    case "$key" in
      COMPRESS|DESKEW|OCR|OPEN_RESULT)
        val=$(_to_bool "$val") || { warn "Configuration : ${key} doit valoir true ou false, ignoré."; continue; } ;;
      STRIP_META)
        case "${val,,}" in
          all|nodates) val="${val,,}" ;;
          false|non|no|0|"") val=false ;;
          *) warn "Configuration : STRIP_META doit valoir all, nodates ou false, ignoré."; continue ;;
        esac ;;
      OUTPUT_DIR) val=$(_clean_path "$val") ;;
    esac
    printf -v "$key" '%s' "$val"
  done < "$CONFIG_FILE"
}

# Écrit les réglages courants dans le fichier de configuration
save_config() {
  local dir; dir=$(dirname -- "$CONFIG_FILE")
  mkdir -p -- "$dir" || error "Impossible de créer le dossier ${dir}"
  local tmp; tmp=$(mktemp "${CONFIG_FILE}.XXXXXX") || error "Impossible d'écrire dans ${dir}"
  {
    echo "# Réglages par défaut de scandoc.sh — modifiable à la main."
    echo "# Les options de la ligne de commande restent prioritaires."
    local key val
    for key in "${CONFIG_KEYS[@]}"; do
      val="${!key}"
      val="${val//\\/\\\\}"; val="${val//\"/\\\"}"
      printf '%s="%s"\n' "$key" "$val"
    done
  } > "$tmp"
  mv -- "$tmp" "$CONFIG_FILE"
  success "Réglages enregistrés dans ${CONFIG_FILE}"
}

# Ouvre le fichier produit avec l'application par défaut, sans bloquer le terminal
_open_result() {
  local f="$1" opener=""
  if command -v xdg-open &>/dev/null; then opener="xdg-open"
  elif command -v open &>/dev/null; then opener="open"
  else
    warn "Ouverture impossible : ni xdg-open ni open n'est disponible."
    return 0
  fi
  info "Ouverture de ${f}..."
  nohup "$opener" "$f" >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# _with_ext CHEMIN EXT — remplace l'extension pdf/jpg/jpeg du nom de fichier par EXT.
# Seul le nom de base est examiné : « ./scans/facture » → « ./scans/facture.pdf »,
# et une autre extension est conservée : « facture.2024 » → « facture.2024.pdf ».
_with_ext() {
  local path="$1" ext="$2"
  local base="${path##*/}"
  local cur="${base##*.}"
  if [[ "$base" == *.* ]] && [[ "${cur,,}" =~ ^(pdf|jpg|jpeg)$ ]]; then
    path="${path%.*}"
  fi
  echo "${path}.${ext}"
}

# =============================================================================
#  MENUS INTERACTIFS
# =============================================================================

menu_main() {
  section "Que souhaitez-vous faire ?"
  print_opt "1" "Scanner un document"              "Utilise le scanner connecté au système"          "true"
  print_opt "2" "Traiter un fichier existant"      "Image ou PDF déjà présent sur le disque"
  print_opt "3" "Scanner plusieurs pages"          "Pause entre chaque page, PDF assemblé automatiquement"
  print_opt "4" "Diagnostic des scanners"          "Scanners détectés et réglages qu'ils acceptent"
  print_opt "5" "Réglages par défaut"              "Scanner, résolution, mode, dossier… mémorisés pour la suite"
  print_opt "6" "Quitter"                          ""
  ask_choice "Votre choix" "1" "6"
}

menu_input_file() {
  section "Fichier source à traiter"
  echo -e "    ${DIM}Formats supportés : JPG, PNG, TIFF, BMP, PNM, PDF…${RESET}"
  echo ""
  echo -e "    ${DIM}Vous pouvez glisser-déposer le fichier dans le terminal ; ~ est accepté.${RESET}"
  echo ""
  while true; do
    ask "Chemin complet du fichier" ""
    INPUT_FILE=$(_clean_path "$REPLY")
    if [[ -z "$INPUT_FILE" ]]; then
      warn "Aucun fichier spécifié."
    elif [[ -f "$INPUT_FILE" ]]; then
      break
    else
      warn "Fichier introuvable : $INPUT_FILE"
    fi
  done
  success "Fichier sélectionné : $INPUT_FILE"
}

menu_device() {
  section "Scanner à utiliser"
  local def=1 max=2
  if [[ -n "$DEVICE" ]]; then def=3; max=3; fi
  print_opt "1" "Auto-détection (conseillé)"  "Le scanner détecté, ou un choix proposé s'il y en a plusieurs"  "$([[ $def == 1 ]] && echo true)"
  print_opt "2" "Choisir dans la liste"        "Scanners détectés par SANE, ou saisie de l'identifiant"
  if [[ -n "$DEVICE" ]]; then
    print_opt "3" "Scanner enregistré"         "$DEVICE"  "true"
  fi
  ask_choice "Votre choix" "$def" "$max"

  if [[ "$REPLY" == "1" ]]; then
    DEVICE=""
  elif [[ "$REPLY" == "2" ]]; then
    echo ""
    local lines=()
    mapfile -t lines < <(_list_scanners)
    if [[ ${#lines[@]} -eq 0 ]] && _offer_airscan; then mapfile -t lines < <(_list_scanners); fi
    if [[ ${#lines[@]} -eq 0 ]]; then
      warn "Aucun scanner détecté."
      _no_scanner_hint
      echo ""
      ask "Identifiant du scanner (ex: brother5:net1;dev0), vide = auto-détection" ""
      DEVICE="$REPLY"
      return 0
    fi
    _choose_scanner "${lines[@]}"
  fi
}

menu_format() {
  section "Format du document"
  echo -e "    ${DIM}Définit la zone de scan. En mode auto, le scanner scanne en plein format${RESET}"
  echo -e "    ${DIM}puis les bandes noires sont supprimées automatiquement.${RESET}"
  echo ""
  local def=1 cw=210 ch=297
  case "${PAPER_FORMAT,,}" in
    a4) def=2 ;; a5) def=3 ;; letter) def=4 ;; legal) def=5 ;;
    custom:*|[0-9]*x*)
      def=6
      local dims="${PAPER_FORMAT#custom:}"; cw="${dims%x*}"; ch="${dims#*x}" ;;
  esac
  print_opt "1" "Auto (détection automatique)"  "Scan pleine zone + recadrage intelligent des bords"  "$([[ $def == 1 ]] && echo true)"
  print_opt "2" "A4         210 × 297 mm"        "Standard européen — lettre, facture, contrat"  "$([[ $def == 2 ]] && echo true)"
  print_opt "3" "A5         148 × 210 mm"        "Demi-format A4 — livret, carnet"  "$([[ $def == 3 ]] && echo true)"
  print_opt "4" "Letter     216 × 279 mm"        "Format américain US Letter"  "$([[ $def == 4 ]] && echo true)"
  print_opt "5" "Legal      216 × 356 mm"        "Format américain US Legal (plus long)"  "$([[ $def == 5 ]] && echo true)"
  print_opt "6" "Personnalisé"                   "Saisir largeur et hauteur en millimètres"  "$([[ $def == 6 ]] && echo true)"
  ask_choice "Votre choix" "$def" "6"

  case "$REPLY" in
    1) PAPER_FORMAT="auto" ;;
    2) PAPER_FORMAT="A4" ;;
    3) PAPER_FORMAT="A5" ;;
    4) PAPER_FORMAT="Letter" ;;
    5) PAPER_FORMAT="Legal" ;;
    6)
      ask_int "Largeur en mm" "$cw" 10 2000
      local w="$REPLY"
      ask_int "Hauteur en mm" "$ch" 10 5000
      PAPER_FORMAT="custom:${w}x${REPLY}"
      ;;
  esac
  success "Format : ${PAPER_FORMAT}"
}

menu_resolution() {
  section "Résolution de scan"
  echo -e "    ${DIM}Plus la résolution est élevée, plus l'image est nette — mais le fichier est plus lourd.${RESET}"
  echo ""
  local def=4
  case "$RESOLUTION" in 150) def=1 ;; 300) def=2 ;; 600) def=3 ;; esac
  print_opt "1" "150 dpi  — Rapide / Léger"    "Emails, documents simples              ~0.5 Mo"  "$([[ $def == 1 ]] && echo true)"
  print_opt "2" "300 dpi  — Standard"           "Usage quotidien, bonne qualité         ~2 Mo"    "$([[ $def == 2 ]] && echo true)"
  print_opt "3" "600 dpi  — Haute qualité"      "Contrats, photos, archivage            ~8 Mo"    "$([[ $def == 3 ]] && echo true)"
  print_opt "4" "Valeur personnalisée"           "Saisir un nombre en dpi$([[ $def == 4 ]] && echo " (actuel : ${RESOLUTION})")"  "$([[ $def == 4 ]] && echo true)"
  ask_choice "Votre choix" "$def" "4"

  case "$REPLY" in
    1) RESOLUTION=150 ;;
    2) RESOLUTION=300 ;;
    3) RESOLUTION=600 ;;
    4)
      ask_int "Résolution en dpi (50-4800)" "$RESOLUTION" 50 4800
      RESOLUTION="$REPLY"
      ;;
  esac
  success "Résolution : ${RESOLUTION} dpi"
}

menu_mode() {
  section "Mode de traitement"
  echo -e "    ${DIM}Détermine le filtre appliqué à l'image après le scan.${RESET}"
  echo ""
  local def=1
  case "${MODE,,}" in bw) def=2 ;; color) def=3 ;; scan) def=4 ;; esac
  print_opt "1" "clean  — Nettoyage fond gris"    "Blanchit le fond, préserve couleurs  → lettres, factures"  "$([[ $def == 1 ]] && echo true)"
  print_opt "2" "bw     — Noir et blanc pur"       "Texte noir sur fond blanc, très léger → formulaires, reçus" "$([[ $def == 2 ]] && echo true)"
  print_opt "3" "color  — Normalisation couleurs"  "Booste les couleurs → photos, plans, documents colorés"     "$([[ $def == 3 ]] && echo true)"
  print_opt "4" "scan   — Brut (sans retouche)"    "Pas de traitement, PDF direct du scanner"                   "$([[ $def == 4 ]] && echo true)"
  ask_choice "Votre choix" "$def" "4"

  case "$REPLY" in
    1) MODE="clean" ;;
    2) MODE="bw" ;;
    3) MODE="color" ;;
    4) MODE="scan" ;;
  esac
  success "Mode : ${MODE}"
}

menu_multipage() {
  section "Scan multi-pages"
  echo -e "    ${DIM}Choisissez comment gérer l'enchaînement des pages.${RESET}"
  echo ""
  print_opt "1" "Nombre fixe de pages"          "Vous savez combien de pages scanner"          "true"
  print_opt "2" "Mode continu (sans compter)"    "Scan page par page — vous décidez quand arrêter"
  print_opt "3" "Chargeur automatique (ADF)"     "Toutes les pages du bac d'un coup, sans intervention"
  ask_choice "Votre choix" "1" "3"

  if [[ "$REPLY" == "1" ]]; then
    MULTI_PAGE_MODE="fixed"
    echo ""
    ask_int "Nombre de pages à scanner" "$NB_PAGES" 1 999
    NB_PAGES="$REPLY"
    success "$NB_PAGES page(s) configurée(s)."
  elif [[ "$REPLY" == "2" ]]; then
    MULTI_PAGE_MODE="auto"
    success "Mode continu : vous serez invité après chaque page."
  else
    MULTI_PAGE_MODE="adf"
    echo ""
    echo -ne "  ${BOLD}→${RESET} Pages imprimées recto verso (scanner les deux faces) ? ${DIM}[o/N]${RESET} : "
    read -r _dup
    if [[ "${_dup,,}" == "o" ]]; then DUPLEX=true; else DUPLEX=false; fi
    if $DUPLEX; then
      success "Chargeur automatique, recto verso : placez toutes les pages dans le bac."
    else
      success "Chargeur automatique : placez toutes les pages dans le bac."
    fi
  fi
}

menu_advanced() {
  section "Options avancées (facultatif)"
  echo -e "    ${DIM}Appuyez sur Entrée pour conserver chaque valeur par défaut.${RESET}"
  echo ""

  case "$MODE" in
    clean)
      echo -e "  ${BOLD}Seuil de blanchiment${RESET}  ${DIM}(mode clean)${RESET}"
      echo -e "  ${DIM}Les pixels plus clairs que ce seuil sont forcés en blanc pur.${RESET}"
      echo -e "  ${DIM}  ↑ Monter si le fond gris persiste   ↓ Descendre si les couleurs s'effacent${RESET}"
      ask_int "Seuil (0-100)" "$WHITE_THRESH" 0 100
      WHITE_THRESH="$REPLY"
      echo ""
      ;;
    bw)
      echo -e "  ${BOLD}Seuil de binarisation${RESET}  ${DIM}(mode bw)${RESET}"
      echo -e "  ${DIM}En dessous de ce seuil → noir pur. Au-dessus → blanc pur.${RESET}"
      echo -e "  ${DIM}  ↑ Monter si le fond gris persiste   ↓ Descendre si le texte disparaît${RESET}"
      ask_int "Seuil (0-100)" "$THRESHOLD" 0 100
      THRESHOLD="$REPLY"
      echo ""
      echo -e "  ${BOLD}Flou anti-bruit${RESET}"
      echo -e "  ${DIM}Lisse légèrement l'image avant la binarisation pour réduire le grain.${RESET}"
      echo -e "  ${DIM}  0 = désactivé   1 = léger   2 = moyen (recommandé pour vieux documents)${RESET}"
      ask_int "Rayon de flou (0-3)" "$BLUR" 0 3
      BLUR="$REPLY"
      echo ""
      ;;
    color|scan)
      echo -e "  ${DIM}Aucune option supplémentaire pour le mode « ${MODE} ».${RESET}"
      echo ""
      ;;
  esac

  if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then
    echo -e "  ${BOLD}Compression Ghostscript${RESET}"
    echo -e "  ${DIM}Optimise la taille du PDF final sans perte visible de qualité.${RESET}"
    echo ""
    local def=1; if ! $COMPRESS; then def=2; fi
    print_opt "1" "Activée (recommandé)"  "Réduit significativement la taille du fichier"  "$([[ $def == 1 ]] && echo true)"
    print_opt "2" "Désactivée"            "PDF non optimisé (plus volumineux)"            "$([[ $def == 2 ]] && echo true)"
    ask_choice "Compression" "$def" "2"
    if [[ "$REPLY" == "2" ]]; then COMPRESS=false; else COMPRESS=true; fi
  else
    echo -e "  ${BOLD}Qualité JPEG${RESET}"
    echo -e "  ${DIM}Plus la valeur est haute, meilleure est la qualité — mais le fichier est plus lourd.${RESET}"
    echo -e "  ${DIM}  75 = léger   85 = bon compromis   95 = haute fidélité${RESET}"
    echo ""
    ask_int "Qualité (1-100)" "$JPEG_QUALITY" 1 100
    JPEG_QUALITY="$REPLY"
  fi

  success "Options avancées appliquées."
}

menu_output_format() {
  echo -e "  ${BOLD}Format de sortie${RESET}"
  echo ""
  local def=1; if [[ "$OUTPUT_FORMAT" == "jpeg" || "$OUTPUT_FORMAT" == "jpg" ]]; then def=2; fi
  print_opt "1" "PDF"   "Un seul fichier, idéal pour documents et archivage"      "$([[ $def == 1 ]] && echo true)"
  print_opt "2" "JPEG"  "Image(s) — pratique pour envoyer par email ou partager"  "$([[ $def == 2 ]] && echo true)"
  ask_choice "Votre choix" "$def" "2"
  if [[ "$REPLY" == "2" ]]; then OUTPUT_FORMAT="jpeg"; else OUTPUT_FORMAT="pdf"; fi
  echo ""
}

menu_output() {
  section "Format et fichier de sortie"
  menu_output_format

  local ext; if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then ext="jpg"; else ext="pdf"; fi
  local default_name="scan_$(date +%Y%m%d_%H%M%S).${ext}"
  if $MULTI_PAGE && [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    echo -e "    ${DIM}Mode multi-pages JPEG : les fichiers seront nommés nom_001.jpg, nom_002.jpg…${RESET}"
  else
    echo -e "    ${DIM}Nom du fichier à créer. Laissez vide pour un nom généré automatiquement.${RESET}"
  fi
  if [[ -n "$OUTPUT_DIR" ]]; then
    echo -e "    ${DIM}Un nom sans dossier sera rangé dans : ${OUTPUT_DIR}${RESET}"
  fi
  echo ""
  while true; do
    ask "Nom du fichier (.${ext})" "$default_name"
    OUTPUT=$(_clean_path "$REPLY")
    resolve_output
    local out_dir; out_dir=$(dirname -- "$OUTPUT")
    if [[ ! -d "$out_dir" ]]; then
      warn "Dossier introuvable : ${out_dir}"
      continue
    fi
    local existing; existing=$(_existing_output)
    if [[ -n "$existing" ]]; then
      echo -ne "  ${YELLOW}Le fichier ${BOLD}${existing}${RESET}${YELLOW} existe déjà. L'écraser ?${RESET} ${DIM}[o/N]${RESET} : "
      read -r _ow
      if [[ "${_ow,,}" != "o" ]]; then continue; fi
      OVERWRITE_OK=true
    fi
    break
  done
  success "Format : ${OUTPUT_FORMAT^^}  —  Sortie : $OUTPUT"
}

# Nom de sortie définitif : nom par défaut si vide, dossier OUTPUT_DIR si aucun
# chemin n'est donné, extension selon le format. Peut être rappelée sans effet.
resolve_output() {
  local ext; if [[ "$OUTPUT_FORMAT" == "jpeg" || "$OUTPUT_FORMAT" == "jpg" ]]; then ext="jpg"; else ext="pdf"; fi
  if [[ -z "$OUTPUT" ]]; then OUTPUT="scan_$(date +%Y%m%d_%H%M%S).${ext}"; fi
  if [[ -n "$OUTPUT_DIR" ]] && [[ "$OUTPUT" != */* ]]; then
    OUTPUT="${OUTPUT_DIR%/}/${OUTPUT}"
  fi
  OUTPUT=$(_with_ext "$OUTPUT" "$ext")
}

# Affiche le premier fichier de sortie qui existe déjà (rien sinon). En JPEG
# multi-pages, les fichiers produits s'appellent nom_001.jpg, nom_002.jpg…
_existing_output() {
  if [[ -e "$OUTPUT" ]]; then echo "$OUTPUT"; return 0; fi
  if [[ "$OUTPUT" == *.jpg ]]; then
    local first="${OUTPUT%.jpg}_001.jpg"
    if [[ -e "$first" ]]; then echo "$first"; fi
  fi
  return 0
}

# Refuse d'écraser un fichier existant sans accord : question si le terminal
# est interactif, sinon erreur (utiliser -y pour forcer)
confirm_overwrite() {
  if $FORCE || $OVERWRITE_OK; then return 0; fi
  local existing; existing=$(_existing_output)
  [[ -n "$existing" ]] || return 0
  if [[ -t 0 ]]; then
    echo -ne "  ${YELLOW}Le fichier ${BOLD}${existing}${RESET}${YELLOW} existe déjà. L'écraser ?${RESET} ${DIM}[o/N]${RESET} : "
    read -r _ow
    if [[ "${_ow,,}" == "o" ]]; then OVERWRITE_OK=true; return 0; fi
    error "Annulé : ${existing} existe déjà (choisissez un autre nom avec -o, ou -y pour écraser)."
  fi
  error "${existing} existe déjà — choisissez un autre nom avec -o, ou ajoutez -y pour l'écraser."
}

# Réglages par défaut : enchaîne les menus puis enregistre la configuration
menu_settings() {
  section "Réglages par défaut"
  echo -e "    ${DIM}Ces choix seront proposés par défaut à chaque utilisation, et utilisés en ligne de commande.${RESET}"
  echo -e "    ${DIM}Fichier : ${CONFIG_FILE}${RESET}"
  menu_device
  menu_format
  menu_resolution
  menu_mode
  section "Sortie"
  menu_output_format

  echo -e "  ${BOLD}Dossier de sortie${RESET}"
  echo -e "  ${DIM}Où ranger les fichiers dont le nom est donné sans dossier. Vide = dossier courant.${RESET}"
  while true; do
    ask "Dossier" "${OUTPUT_DIR:-(dossier courant)}"
    if [[ "$REPLY" == "(dossier courant)" ]] || [[ "$REPLY" == "-" ]]; then OUTPUT_DIR=""; break; fi
    OUTPUT_DIR=$(_clean_path "$REPLY")
    if [[ -d "$OUTPUT_DIR" ]]; then break; fi
    echo -ne "  ${BOLD}→${RESET} ${OUTPUT_DIR} n'existe pas. Le créer ? ${DIM}[O/n]${RESET} : "
    read -r _mk
    if [[ "${_mk,,}" != "n" ]] && mkdir -p -- "$OUTPUT_DIR"; then break; fi
  done

  if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then menu_ocr; fi
  menu_meta
  menu_open_result
  validate_options
  save_config
  exit 0
}

menu_open_result() {
  echo ""
  local hint="[o/N]"; if $OPEN_RESULT; then hint="[O/n]"; fi
  echo -ne "  ${BOLD}→${RESET} Ouvrir le fichier à la fin du traitement ? ${DIM}${hint}${RESET} : "
  read -r _open
  if [[ -n "$_open" ]]; then
    if [[ "${_open,,}" == "o" ]]; then OPEN_RESULT=true; else OPEN_RESULT=false; fi
  fi
}

menu_summary() {
  section "Récapitulatif — Prêt à démarrer"
  printf "    %-22s ${CYAN}%s${RESET}\n" "Résolution :"   "${RESOLUTION} dpi"
  printf "    %-22s ${CYAN}%s${RESET}\n" "Mode :"         "$MODE"
  if [[ -z "$INPUT_FILE" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Format papier :" "$PAPER_FORMAT"; fi
  printf "    %-22s ${CYAN}%s${RESET}\n" "Sortie :"       "$OUTPUT"
  if $MULTI_PAGE; then
    if [[ "$MULTI_PAGE_MODE" == "auto" ]]; then
      printf "    %-22s ${CYAN}%s${RESET}\n" "Pages :" "mode continu (au fil de l'eau)"
    elif [[ "$MULTI_PAGE_MODE" == "adf" ]]; then
      printf "    %-22s ${CYAN}%s${RESET}\n" "Pages :" "chargeur automatique$($DUPLEX && echo ", recto verso")${SCAN_SOURCE:+ ($SCAN_SOURCE)}"
    else
      printf "    %-22s ${CYAN}%s${RESET}\n" "Pages :" "$NB_PAGES"
    fi
  fi
  if [[ -n "$INPUT_FILE" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Source :" "$INPUT_FILE"; fi
  if [[ -z "$INPUT_FILE" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Redressement :" "$($DESKEW && echo 'oui' || echo 'non')"; fi
  if [[ -n "$DEVICE" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Scanner :" "$DEVICE"; fi
  if [[ "$MODE" == "bw" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Seuil BW :" "${THRESHOLD}%"; fi
  if [[ "$MODE" == "clean" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Seuil blanc :" "${WHITE_THRESH}%"; fi
  printf "    %-22s ${CYAN}%s${RESET}\n" "Format :"       "${OUTPUT_FORMAT^^}"
  if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then
    printf "    %-22s ${CYAN}%s${RESET}\n" "Compression :"  "$($COMPRESS && echo 'oui' || echo 'non')"
    if $OCR; then
      printf "    %-22s ${CYAN}%s${RESET}\n" "OCR :" "oui (${OCR_LANG})"
    else
      printf "    %-22s ${CYAN}%s${RESET}\n" "OCR :" "non"
    fi
  else
    printf "    %-22s ${CYAN}%s${RESET}\n" "Qualité JPEG :" "${JPEG_QUALITY}"
  fi
  local _meta_label
  case "$STRIP_META" in
    all)     _meta_label="supprimées (tout)" ;;
    nodates) _meta_label="supprimées (sauf dates)" ;;
    *)       _meta_label="conservées" ;;
  esac
  printf "    %-22s ${CYAN}%s${RESET}\n" "Métadonnées :" "$_meta_label"
  printf "    %-22s ${CYAN}%s${RESET}\n" "Ouvrir à la fin :" "$($OPEN_RESULT && echo 'oui' || echo 'non')"
  echo ""
  echo -ne "  ${BOLD}→${RESET} Lancer maintenant ? ${DIM}[O/n]${RESET} : "
  read -r _confirm
  if [[ "${_confirm,,}" == "n" ]]; then
    warn "Traitement annulé."
    exit 0
  fi
}

# =============================================================================
#  MODE INTERACTIF — Enchaînement des menus
# =============================================================================

run_interactive() {
  INTERACTIVE=true
  banner
  check_and_install_deps

  menu_main
  local main_choice="$REPLY"

  case "$main_choice" in
    1)  # Scan simple
        MULTI_PAGE=false; INPUT_FILE=""
        menu_device
        menu_format
        menu_resolution
        menu_mode
        ;;
    2)  # Traiter un fichier existant
        menu_input_file
        menu_mode
        ;;
    3)  # Scan multi-pages
        MULTI_PAGE=true; INPUT_FILE=""
        menu_device
        menu_format
        menu_resolution
        menu_mode
        menu_multipage
        ;;
    4)  run_diagnostic ;;
    5)  menu_settings ;;
    6)  echo "Au revoir !"; exit 0 ;;
  esac

  menu_output

  if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then menu_ocr; fi
  menu_meta

  echo ""
  echo -ne "  ${BOLD}→${RESET} Configurer les options avancées ? ${DIM}[o/N]${RESET} : "
  read -r _adv
  if [[ "${_adv,,}" == "o" ]]; then menu_advanced; fi
  menu_open_result

  validate_options
  menu_summary
  main_process
}

# =============================================================================
#  USAGE & LISTE DES SCANNERS (mode CLI)
# =============================================================================

usage() {
  cat <<EOF
${BOLD}USAGE${RESET}
  $(basename "$0")            Mode interactif avec menus guidés
  $(basename "$0") [OPTIONS]  Mode ligne de commande

${BOLD}OPTIONS${RESET}
  -r <dpi>       Résolution (défaut: ${RESOLUTION}) — ex: 150, 300, 600
  -m <mode>      Mode de traitement (défaut: ${MODE})
                   scan   : scan brut sans traitement
                   clean  : nettoie fond gris, préserve couleurs
                   bw     : noir/blanc pur (texte, petite taille)
                   color  : normalisation couleur uniquement
  -o <fichier>   Fichier PDF de sortie (défaut: scan_YYYYMMDD_HHMMSS.pdf)
  -f <fichier>   Fichier source existant (skip le scan)
  -t <0-100>     Seuil binarisation mode bw (défaut: ${THRESHOLD})
  -w <0-100>     Seuil blanchiment mode clean (défaut: ${WHITE_THRESH})
  -b <0-3>       Rayon de flou anti-bruit (défaut: ${BLUR}, 0=désactivé)
  -d <device>    Device SANE (défaut: auto-détection)
  -F <format>    Format papier : auto, A4, A5, Letter, Legal, WxH (mm) (défaut: auto)
  -O <format>    Format de sortie : pdf, jpeg (défaut: pdf)
  -R             Activer l'OCR (texte sélectionnable) — nécessite ocrmypdf
  -L <lang>      Langue OCR (défaut: fra+eng) ex: fra, eng, fra+eng
  -M             Supprimer toutes les métadonnées (PDF et JPEG : outils, dates…)
  -p             Mode multi-pages (pause entre chaque page)
  -n <nb>        Nombre de pages en mode multi-pages (défaut: ${NB_PAGES})
  -a             Chargeur automatique (ADF) : scanne toutes les pages du bac
  -2             Recto verso avec le chargeur (aussi --recto-verso, implique -a)
  -S <source>    Source SANE explicite (ex: "ADF Duplex", "Flatbed") — voir -D
  -y             Écraser le fichier de sortie s'il existe déjà
  -V             Ouvrir le fichier produit à la fin (xdg-open)
  -k             Garder les fichiers temporaires
  -C             Désactiver la compression ghostscript
  -s             Ne pas redresser les pages scannées (aussi --sans-redressement)
  -l             Lister les scanners disponibles
  -D             Diagnostic : réglages acceptés par chaque scanner (aussi --diagnostic)
  -h             Afficher cette aide

${BOLD}CONFIGURATION${RESET}
  Réglages par défaut lus dans : ${CONFIG_FILE}
  (à créer via le menu « Réglages par défaut », ou à la main : CLÉ="valeur").
  Les options ci-dessus restent prioritaires.

${BOLD}EXEMPLES${RESET}
  $(basename "$0") -o contrat.pdf
  $(basename "$0") -r 600 -m color -o photo.pdf
  $(basename "$0") -f scan_existant.jpg -m bw -t 60
  $(basename "$0") -p -n 5 -o dossier_complet.pdf
  $(basename "$0") -a -m bw -o courrier.pdf
EOF
  exit 0
}

list_devices() {
  command -v scanimage &>/dev/null || error "scanimage introuvable — installe sane-utils"
  info "Recherche des scanners disponibles..."
  local lines=() l
  mapfile -t lines < <(_list_scanners)
  if [[ ${#lines[@]} -eq 0 ]]; then
    warn "Aucun scanner détecté."
    _no_scanner_hint
    exit 0
  fi
  for l in "${lines[@]}"; do
    IFS=$'\t' read -r _dev _name _type <<< "$l"
    printf "    ${BOLD}%s${RESET}  ${DIM}%s — %s${RESET}\n" "$_name" "$_dev" "$_type"
  done
  echo -e "\n    ${DIM}Choisir un scanner : -d <identifiant>   Détails : -D${RESET}"
  exit 0
}

# =============================================================================
#  PARSING DES OPTIONS (mode CLI)
# =============================================================================

load_config

# Options longues reconnues : --diagnostic, --help
_args=()
for _a in "$@"; do
  case "$_a" in
    --diagnostic) _args+=("-D") ;;
    --recto-verso|--duplex) _args+=("-2") ;;
    --sans-redressement) _args+=("-s") ;;
    --help)       _args+=("-h") ;;
    *)            _args+=("$_a") ;;
  esac
done
set -- "${_args[@]}"
unset _args _a

while getopts "r:m:o:f:t:w:b:d:F:O:L:n:S:apkyVCRMDlhs2" opt; do
  case $opt in
    r) RESOLUTION="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    f) INPUT_FILE="$OPTARG" ;;
    t) THRESHOLD="$OPTARG" ;;
    w) WHITE_THRESH="$OPTARG" ;;
    b) BLUR="$OPTARG" ;;
    d) DEVICE="$OPTARG" ;;
    F) PAPER_FORMAT="$OPTARG" ;;
    O) OUTPUT_FORMAT="$OPTARG" ;;
    L) OCR_LANG="$OPTARG" ;;
    n) NB_PAGES="$OPTARG" ;;
    p) MULTI_PAGE=true ;;
    a) MULTI_PAGE=true; MULTI_PAGE_MODE="adf" ;;
    2) DUPLEX=true ;;
    S) SCAN_SOURCE="$OPTARG" ;;
    k) KEEP_TEMP=true ;;
    y) FORCE=true ;;
    V) OPEN_RESULT=true ;;
    C) COMPRESS=false ;;
    s) DESKEW=false ;;
    R) OCR=true ;;
    M) STRIP_META=all ;;
    D) DIAGNOSTIC=true ;;
    l) LIST_ONLY=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

# =============================================================================
#  VALIDATION DES OPTIONS (avant tout scan)
# =============================================================================

# _check_int NOM VALEUR MIN MAX — erreur si VALEUR n'est pas un entier dans [MIN, MAX]
_check_int() {
  local name="$1" val="$2" min="$3" max="$4"
  if [[ ! "$val" =~ ^[0-9]+$ ]] || (( 10#$val < min || 10#$val > max )); then
    error "${name} invalide : « ${val} » — attendu un entier entre ${min} et ${max}."
  fi
}

# Normalise et vérifie toutes les options, pour échouer tout de suite plutôt
# qu'après un scan.
validate_options() {
  MODE="${MODE,,}"
  case "$MODE" in
    scan|clean|bw|color) ;;
    *) error "Mode invalide : « ${MODE} » — valeurs possibles : scan, clean, bw, color." ;;
  esac

  OUTPUT_FORMAT="${OUTPUT_FORMAT,,}"
  case "$OUTPUT_FORMAT" in
    pdf) ;;
    jpeg|jpg) OUTPUT_FORMAT="jpeg" ;;
    *) error "Format de sortie invalide : « ${OUTPUT_FORMAT} » — valeurs possibles : pdf, jpeg (ou jpg)." ;;
  esac

  _check_int "Résolution (-r)"          "$RESOLUTION"   50 4800
  _check_int "Nombre de pages (-n)"     "$NB_PAGES"     1  999
  _check_int "Seuil bw (-t)"            "$THRESHOLD"    0  100
  _check_int "Seuil de blanchiment (-w)" "$WHITE_THRESH" 0  100
  _check_int "Flou (-b)"                "$BLUR"         0  3
  _check_int "Qualité JPEG"             "$JPEG_QUALITY" 1  100
  RESOLUTION=$((10#$RESOLUTION)); NB_PAGES=$((10#$NB_PAGES))
  THRESHOLD=$((10#$THRESHOLD)); WHITE_THRESH=$((10#$WHITE_THRESH))
  BLUR=$((10#$BLUR)); JPEG_QUALITY=$((10#$JPEG_QUALITY))

  if [[ ! "$OCR_LANG" =~ ^[a-z_]+(\+[a-z_]+)*$ ]]; then
    error "Langue OCR invalide : « ${OCR_LANG} » — ex : fra, eng, fra+eng."
  fi

  normalize_paper_format

  if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || error "Fichier introuvable : $INPUT_FILE"
    if $MULTI_PAGE; then warn "-f fourni : le mode multi-pages / chargeur est ignoré."; fi
  fi
  if [[ -n "$OUTPUT_DIR" ]] && [[ ! -d "$OUTPUT_DIR" ]]; then
    mkdir -p -- "$OUTPUT_DIR" || error "Impossible de créer le dossier de sortie : ${OUTPUT_DIR}"
  fi
  resolve_output
  if [[ -n "$OUTPUT" ]]; then
    local out_dir; out_dir=$(dirname -- "$OUTPUT")
    [[ -d "$out_dir" ]] || error "Dossier de sortie introuvable : ${out_dir}"
    [[ -w "$out_dir" ]] || error "Dossier de sortie non accessible en écriture : ${out_dir}"
  fi
  # -n sans -p : on suppose que plusieurs pages sont voulues
  if [[ -z "$INPUT_FILE" ]] && ! $MULTI_PAGE && (( NB_PAGES > 1 )); then
    info "-n ${NB_PAGES} sans -p : mode multi-pages activé."
    MULTI_PAGE=true
  fi
  # Le recto verso passe par le chargeur : les deux faces sont des pages distinctes
  if $DUPLEX && [[ -z "$INPUT_FILE" ]] && [[ "$MULTI_PAGE_MODE" != "adf" ]]; then
    info "Recto verso : chargeur automatique activé."
    MULTI_PAGE=true; MULTI_PAGE_MODE="adf"
  fi
  if $OCR && [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    warn "L'OCR ne s'applique qu'au PDF : ignoré pour une sortie JPEG."
    OCR=false
  fi
}

# =============================================================================
#  SCANNERS ET CAPACITÉS (SANE)
# =============================================================================
#
# SANE rend le script indépendant de la marque, mais chaque pilote nomme ses
# réglages à sa façon (« Color », « 24bit Color », « True Gray »…) et n'accepte
# que certaines résolutions et une zone maximale. On lit donc une fois les
# options du scanner (scanimage -A) et on s'y adapte avant le premier scan.

# Scanners détectés, un par ligne : « identifiant<TAB>marque modèle<TAB>type ».
# Les webcams (pilote v4l, type « video camera ») sont écartées.
_list_scanners() {
  { scanimage -f $'%d\t%v %m\t%t\n' 2>/dev/null || true; } \
    | awk -F'\t' 'NF >= 3 && $1 != "" && $1 !~ /^v4l:/ && tolower($3) !~ /camera/'
}

_airscan_installed() {
  [[ -f /etc/sane.d/airscan.conf ]] || [[ -f /usr/local/etc/sane.d/airscan.conf ]]
}

# Conseils quand aucun scanner n'est trouvé
_no_scanner_hint() {
  echo -e "    ${DIM}→ Vérifiez que le scanner est allumé, branché en USB ou sur le même réseau.${RESET}"
  if ! _airscan_installed; then
    echo -e "    ${DIM}→ Beaucoup de scanners réseau ou récents marchent sans pilote avec sane-airscan :${RESET}"
    echo -e "    ${DIM}  sudo apt install sane-airscan${RESET}"
  fi
  echo -e "    ${DIM}→ Sinon, installez le pilote SANE du fabricant, puis vérifiez avec : scanimage -L${RESET}"
}

# Mode interactif, aucun scanner trouvé : propose d'installer sane-airscan.
# Retourne 0 s'il vient d'être installé (il faut alors relancer la recherche).
_offer_airscan() {
  $INTERACTIVE || return 1
  _airscan_installed && return 1
  command -v apt &>/dev/null || return 1
  warn "Aucun scanner détecté."
  echo -e "    ${DIM}sane-airscan permet d'utiliser sans pilote la plupart des scanners réseau ou récents.${RESET}"
  echo -ne "  ${BOLD}→${RESET} Installer sane-airscan maintenant ? ${DIM}[o/N]${RESET} : "
  read -r _ans
  [[ "${_ans,,}" == "o" ]] || return 1
  if sudo apt install -y sane-airscan; then
    success "sane-airscan installé, nouvelle recherche..."
    return 0
  fi
  warn "Échec de l'installation de sane-airscan."
  return 1
}

# Menu de choix parmi les lignes de _list_scanners (+ saisie libre) → DEVICE
_choose_scanner() {
  local lines=("$@") i=0 l dev name type
  for l in "${lines[@]}"; do
    i=$(( i + 1 ))
    IFS=$'\t' read -r dev name type <<< "$l"
    print_opt "$i" "$name" "$dev"
  done
  print_opt "$(( i + 1 ))" "Autre" "Saisir l'identifiant SANE à la main"
  ask_choice "Scanner" "1" "$(( i + 1 ))"
  if (( REPLY <= i )); then
    DEVICE="${lines[REPLY-1]%%$'\t'*}"
  else
    ask "Identifiant du scanner (ex: brother5:net1;dev0)" ""
    DEVICE="$REPLY"
  fi
  if [[ -n "$DEVICE" ]]; then success "Scanner : ${DEVICE}"; fi
}

# Aucun scanner imposé (-d ou réglages) : prend le seul détecté ; s'il y en a
# plusieurs, demande lequel (mode interactif) ou prend le premier (mode CLI).
_pick_scanner() {
  local lines=()
  info "Recherche des scanners..."
  mapfile -t lines < <(_list_scanners)
  if [[ ${#lines[@]} -eq 0 ]] && _offer_airscan; then mapfile -t lines < <(_list_scanners); fi

  if [[ ${#lines[@]} -eq 0 ]]; then
    echo -e "${RED}[ERR]${RESET}  Aucun scanner détecté." >&2
    _no_scanner_hint >&2
    exit 1
  fi

  local dev name type
  if [[ ${#lines[@]} -eq 1 ]]; then
    IFS=$'\t' read -r dev name type <<< "${lines[0]}"
    DEVICE="$dev"
    info "Scanner : ${name} (${dev})"
  elif $INTERACTIVE; then
    section "Plusieurs scanners détectés"
    _choose_scanner "${lines[@]}"
  else
    IFS=$'\t' read -r dev name type <<< "${lines[0]}"
    DEVICE="$dev"
    warn "${#lines[@]} scanners détectés, utilisé : ${name} (${dev})"
    local l
    for l in "${lines[@]:1}"; do
      IFS=$'\t' read -r dev name type <<< "$l"
      echo -e "    ${DIM}autre : ${name}  →  -d \"${dev}\"${RESET}"
    done
  fi
}

# Lit les options du scanner (scanimage -A) pour DEVICE et SCAN_SOURCE, une
# seule fois par couple scanner/source (la zone maximale dépend de la source).
# CAPS_OK=false si elles sont illisibles : on garde alors les réglages standard.
_load_caps() {
  local key="${DEVICE}|${SCAN_SOURCE}"
  [[ "$CAPS_KEY" == "$key" ]] && return 0
  CAPS_KEY="$key"
  local opts=()
  if [[ -n "$DEVICE" ]]; then opts+=("--device-name=$DEVICE"); fi
  if [[ -n "$SCAN_SOURCE" ]]; then opts+=("--source=$SCAN_SOURCE"); fi
  if SCANNER_CAPS=$(scanimage "${opts[@]}" -A 2>/dev/null) && [[ -n "$SCANNER_CAPS" ]]; then
    CAPS_OK=true
  else
    SCANNER_CAPS=""
    CAPS_OK=false
  fi
}

# Valeurs d'une option du scanner, sans la valeur par défaut ni le pas :
#   « --mode Lineart|Gray|Color [Color] »                   → « Lineart|Gray|Color »
#   « --resolution 50..1200dpi (in steps of 1) [300] »      → « 50..1200dpi »
# Code retour 1 si le scanner n'a pas cette option.
_cap_values() {
  local opt="$1" line
  line=$(grep -m1 -E -- "^[[:space:]]*${opt}[[:space:]]" <<< "$SCANNER_CAPS" || true)
  [[ -n "$line" ]] || return 1
  line="${line#*"${opt}" }"
  line="${line% \[*}"
  line="${line%% (in steps of*}"
  printf '%s' "$line"
}

# Pas d'une option à plage (« (in steps of 50) »), vide sinon
_cap_step() {
  local line
  line=$(grep -m1 -E -- "^[[:space:]]*$1[[:space:]]" <<< "$SCANNER_CAPS" || true)
  if [[ "$line" =~ \(in\ steps\ of\ ([0-9.]+)\) ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# Nom du mode SANE pour « color » ou « gray » dans le vocabulaire du pilote :
#   Color, Colour, 24bit Color…  /  Gray, Grey, Grayscale, True Gray…
# Préfère le nom exact, puis un nom sans variante « [Fast] ». Vide si aucun.
# Code retour 1 si le scanner n'a pas d'option --mode.
_pick_mode_name() {
  local want="$1" list m low best=""
  list=$(_cap_values "--mode") || return 1
  local IFS='|' vals=()
  read -ra vals <<< "$list"
  for m in "${vals[@]}"; do
    low="${m,,}"
    if [[ "$want" == "color" ]]; then
      [[ "$low" =~ colou?r ]] || continue
      if [[ "$low" =~ ^colou?r$ ]]; then echo "$m"; return 0; fi
    else
      [[ "$low" =~ gr[ae]y ]] || continue
      [[ "$low" =~ (diffusion|dither|halftone) ]] && continue
      if [[ "$low" =~ ^gr[ae]y(scale)?$ ]]; then echo "$m"; return 0; fi
    fi
    if [[ -z "$best" ]] || { [[ "$best" == *\[* ]] && [[ "$m" != *\[* ]]; }; then best="$m"; fi
  done
  echo "$best"
}

# Résolution acceptée par le scanner la plus proche de $1 (liste de valeurs ou
# plage avec pas). Affiche $1 inchangée si le scanner ne précise rien.
_fit_resolution() {
  local want="$1" spec step
  spec=$(_cap_values "--resolution") || { echo "$want"; return 0; }
  step=$(_cap_step "--resolution")
  awk -v want="$want" -v spec="${spec//dpi/}" -v step="${step:-0}" 'BEGIN {
    if (index(spec, "..")) {
      split(spec, r, /\.\./); min = r[1] + 0; max = r[2] + 0
      v = want
      if (max > 0 && v > max) v = max
      if (v < min) v = min
      if (step > 1) v = min + int((v - min) / step + 0.5) * step
      if (max > 0 && v > max) v -= step
      printf "%d\n", v + 0.5; exit
    }
    n = split(spec, vals, "|"); best = ""
    for (i = 1; i <= n; i++) {
      if (vals[i] !~ /^[0-9]+([.][0-9]+)?$/) continue
      d = vals[i] - want; if (d < 0) d = -d
      if (best == "" || d < bd || (d == bd && vals[i] + 0 > best + 0)) { best = vals[i]; bd = d }
    }
    if (best == "") best = want
    printf "%d\n", best + 0.5
  }'
}

# Taille maximale en mm d'une option de zone (-x ou -y), vide si inconnue
_cap_max_mm() {
  local spec
  spec=$(_cap_values "$1") || return 0
  if [[ "$spec" =~ \.\.([0-9]+([.][0-9]+)?)mm ]]; then echo "${BASH_REMATCH[1]}"; fi
}

# Source de type chargeur (ADF / Feeder) parmi les sources du scanner :
# recto simple de préférence, ou recto verso si $1 vaut « duplex ». Rien si aucune.
_detect_adf_source() {
  local want="${1:-simplex}" list
  list=$(_cap_values "--source") || return 0
  local IFS='|' src candidates=()
  read -ra candidates <<< "$list"
  for src in "${candidates[@]}"; do
    [[ "${src,,}" =~ (adf|feeder) ]] || continue
    if [[ "$want" == "duplex" ]]; then
      [[ "${src,,}" =~ duplex ]] && { echo "$src"; return 0; }
    else
      [[ "${src,,}" =~ duplex ]] || { echo "$src"; return 0; }
    fi
  done
  [[ "$want" == "duplex" ]] && return 0
  for src in "${candidates[@]}"; do
    if [[ "${src,,}" =~ (adf|feeder) ]]; then echo "$src"; return 0; fi
  done
}

# Adapte le mode couleur, la résolution et la zone de scan aux options lues.
_adapt_to_caps() {
  local want=color fallback=Color
  if [[ "$MODE" == "bw" ]]; then want=gray; fallback=Gray; fi

  # --- Mode couleur ---
  SCAN_MODE_NAME="$fallback"
  if $CAPS_OK; then
    local name="" other=color
    [[ "$want" == "color" ]] && other=gray
    if ! name=$(_pick_mode_name "$want"); then
      SCAN_MODE_NAME=""   # pas d'option --mode : réglage propre au scanner
    else
      # Sans niveaux de gris, on scanne en couleur (le traitement convertit), et inversement
      [[ -n "$name" ]] || name=$(_pick_mode_name "$other")
      if [[ -n "$name" ]]; then
        SCAN_MODE_NAME="$name"
      else
        SCAN_MODE_NAME=""
        warn "Aucun mode couleur ou gris reconnu ($(_cap_values "--mode")) : mode par défaut du scanner."
      fi
    fi
  fi

  # --- Résolution ---
  SCAN_RES_OPT=true
  if $CAPS_OK; then
    if _cap_values "--resolution" >/dev/null; then
      local fit; fit=$(_fit_resolution "$RESOLUTION")
      if [[ "$fit" =~ ^[0-9]+$ ]] && (( fit != RESOLUTION )); then
        warn "Résolution ${RESOLUTION} dpi non acceptée par le scanner : ${fit} dpi utilisée."
        RESOLUTION="$fit"
      fi
    else
      SCAN_RES_OPT=false
      warn "Le scanner ne propose pas de réglage de résolution : résolution par défaut du scanner."
    fi
  fi

  # --- Zone de scan ---
  SCAN_SIZE_OPTS=()
  local dims w h
  dims=$(_paper_dims)
  [[ -n "$dims" ]] || return 0
  read -r w h <<< "$dims"
  if $CAPS_OK; then
    if ! _cap_values "-x" >/dev/null || ! _cap_values "-y" >/dev/null; then
      warn "Le scanner ne permet pas de choisir la zone : scan en plein format."
      return 0
    fi
    local max_x max_y
    max_x=$(_cap_max_mm "-x"); max_y=$(_cap_max_mm "-y")
    if [[ -n "$max_x" ]] && awk -v a="$w" -v b="$max_x" 'BEGIN { exit !(a > b) }'; then
      warn "Largeur ${w} mm plus grande que la zone du scanner : limitée à ${max_x} mm."
      w="$max_x"
    fi
    if [[ -n "$max_y" ]] && awk -v a="$h" -v b="$max_y" 'BEGIN { exit !(a > b) }'; then
      warn "Hauteur ${h} mm plus grande que la zone du scanner : limitée à ${max_y} mm."
      h="$max_y"
    fi
  fi
  SCAN_SIZE_OPTS=("-x" "$w" "-y" "$h")
}

# Message d'erreur de scanimage sans les lignes de progression ni les
# avertissements sans conséquence (« rounded value of br-y… »)
_scan_error_text() {
  grep -v -e '^Scanning' -e '^Scanned' -e 'rounded value of' "$1" || true
}

# Conseil adapté à l'erreur de scanimage ($1), sinon le conseil par défaut ($2)
_scan_error_hint() {
  local low="${1,,}"
  if [[ "$low" =~ (out\ of\ documents|no\ more\ documents|no\ documents|feeder) ]]; then
    echo "Le bac du chargeur est vide : placez la feuille dans le bac, puis relancez."
  elif [[ "$low" =~ (jammed|jam) ]]; then
    echo "Bourrage papier : dégagez la feuille, puis relancez."
  elif [[ "$low" =~ (busy|in\ use) ]]; then
    echo "Le scanner est occupé (autre logiciel ouvert ?) : fermez-le, puis relancez."
  elif [[ "$low" =~ (invalid\ argument) ]]; then
    echo "Le scanner refuse un réglage : voir ce qu'il accepte avec -D."
  else
    echo "$2"
  fi
}

# Avant le premier scan : choix du scanner, source du chargeur, puis adaptation
# des réglages à ce que le scanner accepte.
prepare_scanner() {
  if [[ -z "$DEVICE" ]]; then _pick_scanner; fi

  if $MULTI_PAGE && [[ "$MULTI_PAGE_MODE" == "adf" ]] && [[ -z "$SCAN_SOURCE" ]]; then
    _load_caps
    if $DUPLEX; then SCAN_SOURCE=$(_detect_adf_source duplex); fi
    if [[ -n "$SCAN_SOURCE" ]]; then
      info "Recto verso : source « ${SCAN_SOURCE} »."
    else
      if $DUPLEX && $CAPS_OK; then
        warn "Ce scanner ne propose pas de source recto verso : seul le recto sera scanné."
      fi
      SCAN_SOURCE=$(_detect_adf_source)
      if [[ -n "$SCAN_SOURCE" ]]; then
        info "Source chargeur détectée : ${SCAN_SOURCE}"
      else
        warn "Aucune source « ADF » détectée : le scanner utilisera sa source par défaut."
        echo -e "    ${DIM}Pour la forcer : -S \"<source>\" (voir -D).${RESET}"
      fi
    fi
  fi

  # Scanner sans vitre (à défilement) et aucune source imposée : pour une page à
  # la fois, le chargeur en recto simple plutôt que la source par défaut du
  # pilote (souvent le recto verso)
  if [[ -z "$SCAN_SOURCE" ]]; then
    _load_caps
    local sources
    if sources=$(_cap_values "--source") && [[ ! "${sources,,}" =~ (flatbed|platen|glass) ]]; then
      SCAN_SOURCE=$(_detect_adf_source)
      if [[ -n "$SCAN_SOURCE" ]]; then
        info "Scanner sans vitre : source « ${SCAN_SOURCE} » (placez la feuille dans le bac)."
      fi
    fi
  fi

  _load_caps
  if ! $CAPS_OK; then
    warn "Options du scanner illisibles : réglages standard utilisés (Color/Gray, ${RESOLUTION} dpi)."
  fi
  _adapt_to_caps
}

# Ligne « libellé  valeur » alignée (compte les caractères, pas les octets)
_diag_row() {
  printf "    %s%*s %b\n" "$1" $(( 22 - ${#1} > 0 ? 22 - ${#1} : 0 )) "" "$2"
}

# Diagnostic (-D / --diagnostic / menu) : scanners détectés et, pour chacun,
# ce qu'il accepte et ce que scandoc utilisera.
run_diagnostic() {
  command -v scanimage &>/dev/null || error "scanimage introuvable — installe sane-utils"
  section "Diagnostic des scanners"
  info "$(scanimage --version 2>/dev/null | head -1)"
  if _airscan_installed; then info "sane-airscan : installé"; else info "sane-airscan : non installé"; fi

  local lines=() l
  info "Recherche des scanners..."
  mapfile -t lines < <(_list_scanners)
  if [[ -n "$DEVICE" ]]; then
    # Scanner imposé (-d ou réglages) : lui seul, même s'il n'est pas listé
    local found=""
    for l in "${lines[@]}"; do [[ "${l%%$'\t'*}" == "$DEVICE" ]] && found="$l"; done
    lines=("${found:-${DEVICE}$'\t'${DEVICE}$'\t'non listé par SANE}")
  fi
  if [[ ${#lines[@]} -eq 0 ]]; then
    warn "Aucun scanner détecté."
    _no_scanner_hint
    exit 0
  fi

  local dev name type src_given="$SCAN_SOURCE"
  for l in "${lines[@]}"; do
    IFS=$'\t' read -r dev name type <<< "$l"
    echo ""
    echo -e "  ${BOLD}${name}${RESET}  ${DIM}${dev} — ${type}${RESET}"
    DEVICE="$dev"; SCAN_SOURCE="$src_given"; CAPS_KEY=""
    _load_caps
    if ! $CAPS_OK; then
      warn "Options illisibles (scanner occupé, éteint ou injoignable ?)."
      continue
    fi

    local v
    v=$(_cap_values "--source") || v="—"
    _diag_row "Sources :" "${v//|/, }"
    v=$(_detect_adf_source); _diag_row "Chargeur (-a) :" "${v:-aucun détecté}"
    v=$(_detect_adf_source duplex); _diag_row "Recto verso (-2) :" "${v:-non proposé}"
    if v=$(_cap_values "--mode"); then
      _diag_row "Modes :" "${v//|/, }"
      local c g
      c=$(_pick_mode_name color); g=$(_pick_mode_name gray)
      _diag_row "→ couleur :" "${c:-${YELLOW}non reconnu${RESET}}"
      _diag_row "→ noir et blanc (bw) :" "${g:-${c:-${YELLOW}non reconnu${RESET}}}"
    else
      _diag_row "Modes :" "pas d'option --mode"
    fi
    if v=$(_cap_values "--resolution"); then
      _diag_row "Résolutions :" "${v//|/, }"
      _diag_row "→ 150 / 300 / 600 :" "$(_fit_resolution 150) / $(_fit_resolution 300) / $(_fit_resolution 600) dpi"
    else
      _diag_row "Résolutions :" "pas d'option --resolution"
    fi
    local mx my
    mx=$(_cap_max_mm "-x"); my=$(_cap_max_mm "-y")
    if [[ -n "$mx" && -n "$my" ]]; then
      local fits=() f d fw fh
      for f in A5 A4 Letter Legal; do
        PAPER_FORMAT="$f"; d=$(_paper_dims); read -r fw fh <<< "$d"
        if awk -v w="$fw" -v h="$fh" -v X="$mx" -v Y="$my" 'BEGIN { exit !(w <= X && h <= Y) }'; then fits+=("$f"); fi
      done
      _diag_row "Zone maximale :" "${mx} × ${my} mm  (formats complets : ${fits[*]:-aucun})"
    else
      _diag_row "Zone maximale :" "inconnue"
    fi
  done
  echo ""
  echo -e "    ${DIM}Choisir un scanner : -d <identifiant>   Choisir une source : -S \"<source>\"${RESET}"
  exit 0
}

# =============================================================================
#  SCAN
# =============================================================================

# Largeur et hauteur en mm (« 210 297 ») de la zone à scanner selon PAPER_FORMAT.
# En mode "auto" : rien, le scanner utilise sa zone maximale.
_paper_dims() {
  case "$PAPER_FORMAT" in
    A4)     echo "210 297" ;;
    A5)     echo "148 210" ;;
    Letter) echo "215.9 279.4" ;;
    Legal)  echo "215.9 355.6" ;;
    custom:*)
      local dims="${PAPER_FORMAT#custom:}"
      echo "${dims%x*} ${dims#*x}"
      ;;
    *) echo "" ;;
  esac
  return 0
}

# Normalise PAPER_FORMAT (casse, « 210x297 » → « custom:210x297 ») et refuse
# les valeurs inconnues, avant tout scan.
normalize_paper_format() {
  local f="$PAPER_FORMAT"
  f="${f#custom:}"
  case "${f,,}" in
    auto)   PAPER_FORMAT="auto" ;;
    a4)     PAPER_FORMAT="A4" ;;
    a5)     PAPER_FORMAT="A5" ;;
    letter) PAPER_FORMAT="Letter" ;;
    legal)  PAPER_FORMAT="Legal" ;;
    *)
      if [[ "${f,,}" =~ ^[0-9]+([.][0-9]+)?x[0-9]+([.][0-9]+)?$ ]]; then
        PAPER_FORMAT="custom:${f,,}"
      else
        error "Format papier invalide : ${PAPER_FORMAT}\n  → Valeurs possibles : auto, A4, A5, Letter, Legal, ou LxH en mm (ex : 210x297)"
      fi
      ;;
  esac
}

# Options scanimage communes au scan simple et au chargeur : scanner, source,
# mode couleur, zone de scan, format et résolution — résultat dans SCAN_OPTS.
# Le mode, la résolution et la zone ont été adaptés au scanner par prepare_scanner.
_scan_opts() {
  SCAN_OPTS=()
  if [[ -n "$DEVICE" ]]; then SCAN_OPTS+=("--device-name=$DEVICE"); fi
  if [[ -n "$SCAN_SOURCE" ]]; then SCAN_OPTS+=("--source=$SCAN_SOURCE"); fi
  if [[ -n "$SCAN_MODE_NAME" ]]; then SCAN_OPTS+=("--mode=$SCAN_MODE_NAME"); fi
  SCAN_OPTS+=("${SCAN_SIZE_OPTS[@]}" "--format=pnm")
  if $SCAN_RES_OPT; then SCAN_OPTS+=("--resolution=$RESOLUTION"); fi
}

# Bords d'une page scannée : le fond du scanner (souvent noir) apparaît autour
# de la feuille, en triangles quand elle est entrée de travers.
#  1. -deskew      : redresse la page d'après l'inclinaison des lignes (si DESKEW)
#  2. -trim        : en format auto, recadre sur la feuille
#  3. remplissage  : ce qui reste du fond sombre touchant le bord devient blanc
#                    (une bordure noire de 1 px relie tous les bords entre eux)
#  4. -extent      : en format fixe, on revient aux dimensions demandées
_edges_msg() {
  if $DESKEW; then info "Redressement et nettoyage des bords..."; else info "Nettoyage des bords..."; fi
}

_clean_edges() {
  local file="$1"
  local args=() size=""
  [[ "$PAPER_FORMAT" != "auto" ]] && size=$(identify -format '%wx%h' "$file" 2>/dev/null || true)
  if $DESKEW; then
    args+=("-background" "black" "-deskew" "40%" "+repage")
  fi
  if [[ "$PAPER_FORMAT" == "auto" ]]; then
    args+=("-fuzz" "25%" "-trim" "+repage")
  fi
  args+=("-bordercolor" "black" "-border" "1" "-fuzz" "25%" "-fill" "white"
         "-draw" "color 0,0 floodfill" "-shave" "1x1" "+repage")
  if [[ -n "$size" ]]; then
    args+=("-background" "white" "-gravity" "center" "-extent" "$size")
  fi
  [[ ${#args[@]} -gt 0 ]] || return 0
  local tmp
  tmp=$(mktemp --suffix=.pnm)
  if convert "$file" "${args[@]}" "$tmp" 2>/dev/null; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    warn "Nettoyage des bords échoué, image conservée telle quelle."
  fi
}

do_scan() {
  local outfile="$1"
  _scan_opts

  info "Scan en cours (${RESOLUTION} dpi, format ${PAPER_FORMAT}, mode ${MODE})..."

  local scan_err
  scan_err=$(mktemp)
  if ! scanimage "${SCAN_OPTS[@]}" > "$outfile" 2>"$scan_err"; then
    local msg
    msg=$(_scan_error_text "$scan_err")
    rm -f "$scan_err"
    error "Échec du scan : ${msg:-erreur inconnue}\n  → $(_scan_error_hint "$msg" "Vérifiez que le document est chargé et le scanner prêt.")"
  fi
  rm -f "$scan_err"

  _edges_msg
  _clean_edges "$outfile"

  success "Scan terminé → $outfile"
}

# Scan de tout le bac du chargeur en une seule commande (scanimage --batch).
# Remplit PAGES avec les pages traitées.
do_scan_adf() {
  local tmpdir="$1"
  _scan_opts

  info "Scan du chargeur en cours (${RESOLUTION} dpi, format ${PAPER_FORMAT}, mode ${MODE})..."
  local scan_err
  scan_err=$(mktemp)
  # Le code retour de scanimage n'est pas fiable en mode batch (« plus de
  # documents » en fin de bac) : on juge sur les pages réellement produites.
  scanimage "${SCAN_OPTS[@]}" --batch="${tmpdir}/adf_%03d.pnm" 2>"$scan_err" || true

  local raw=()
  shopt -s nullglob
  raw=("${tmpdir}"/adf_*.pnm)
  shopt -u nullglob
  # Une page vide (0 octet) peut être laissée par un bourrage ou un bac vide
  local f pages_ok=()
  for f in "${raw[@]}"; do [[ -s "$f" ]] && pages_ok+=("$f"); done

  if [[ ${#pages_ok[@]} -eq 0 ]]; then
    local msg; msg=$(_scan_error_text "$scan_err")
    rm -f "$scan_err"
    error "Aucune page scannée depuis le chargeur : ${msg:-erreur inconnue}\n  → Vérifiez que les pages sont dans le bac et que le scanner a un chargeur (-S pour choisir la source)."
  fi
  rm -f "$scan_err"
  success "${#pages_ok[@]} page(s) scannée(s) depuis le chargeur."

  local n=0
  for f in "${pages_ok[@]}"; do
    n=$(( n + 1 ))
    echo -e "${BOLD}--- Page ${n}/${#pages_ok[@]} ---${RESET}"
    _edges_msg
    _clean_edges "$f"
    local proc_tmp="${tmpdir}/page_${n}_processed.$(_page_ext)"
    do_process "$f" "$proc_tmp"
    PAGES+=("$proc_tmp")
  done
}

# =============================================================================
#  POST-TRAITEMENT IMAGEMAGICK
# =============================================================================

do_process() {
  local infile="$1"
  local outfile="$2"

  info "Post-traitement (mode: ${MODE})..."

  # Construction du pipeline ImageMagick selon le mode
  local im_args=("-depth" "8")

  case "$MODE" in
    scan)
      # Pas de traitement, juste conversion en PDF
      ;;

    clean)
      # -normalize         : étire l'histogramme pour maximiser le contraste
      # -white-threshold   : force en blanc les pixels > seuil (élimine le fond gris)
      im_args+=("-normalize" "-white-threshold" "${WHITE_THRESH}%")
      ;;

    bw)
      # -colorspace Gray   : conversion en niveaux de gris
      # -blur              : flou optionnel anti-grain avant binarisation
      # -normalize         : boost du contraste
      # -threshold         : binarisation dure (0 ou 255)
      im_args+=("-colorspace" "Gray")
      if [[ "$BLUR" -gt 0 ]]; then im_args+=("-blur" "0x${BLUR}"); fi
      im_args+=("-normalize" "-threshold" "${THRESHOLD}%")
      ;;

    color)
      # -normalize               : boost du contraste
      # -modulate 100,110,100    : brightness 100%, saturation +10%, hue inchangé
      im_args+=("-normalize" "-modulate" "100,110,100")
      ;;

    *)
      error "Mode inconnu : ${MODE}. Valeurs valides : scan | clean | bw | color"
      ;;
  esac

  # Résolution : sans elle, ImageMagick suppose 72 dpi et la page du PDF
  # devient gigantesque (A4 à 300 dpi → 87 × 124 cm). Le PNM (scan, PDF source)
  # ne porte aucune résolution ; pour une image, on garde la sienne si elle existe.
  local units=""
  if [[ "$infile" != *.pnm ]]; then
    units=$(identify -format '%U' "${infile}[0]" 2>/dev/null || true)
  fi
  if [[ -z "$units" ]] || [[ "$units" == "Undefined" ]]; then
    im_args+=("-units" "PixelsPerInch" "-density" "$RESOLUTION")
  fi

  # Qualité JPEG si applicable
  if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    im_args+=("-quality" "$JPEG_QUALITY")
  fi

  convert "$infile" "${im_args[@]}" "$outfile" \
    || error "Échec du post-traitement ImageMagick"

  success "Post-traitement terminé → $outfile"
}

# Outils de nettoyage PDF manquants (exiftool : XMP et Producer ; qpdf : réécrit
# le fichier pour que les anciennes valeurs ne soient plus récupérables)
_missing_pdf_meta_tools() {
  local m=()
  command -v exiftool &>/dev/null || m+=("libimage-exiftool-perl")
  command -v qpdf     &>/dev/null || m+=("qpdf")
  echo "${m[*]}"
}

menu_meta() {
  while true; do
    section "Métadonnées"
    if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then
      echo -e "    ${DIM}Le PDF contient des informations sur les outils utilisés (ImageMagick, OCRmyPDF,${RESET}"
      echo -e "    ${DIM}Ghostscript…) ainsi que les dates de création et de modification.${RESET}"
    else
      echo -e "    ${DIM}Le fichier JPEG peut contenir des métadonnées EXIF (outil, logiciel, dates…).${RESET}"
    fi
    echo -e "    ${DIM}Les supprimer améliore la confidentialité du fichier.${RESET}"
    echo ""
    local def=3
    case "$STRIP_META" in all) def=1 ;; nodates) def=2 ;; esac
    print_opt "1" "Supprimer tout"            "Outils, dates, tous les champs vidés"                 "$([[ $def == 1 ]] && echo true)"
    print_opt "2" "Supprimer sauf les dates"  "Vide l'outil source, conserve CreationDate/ModDate"  "$([[ $def == 2 ]] && echo true)"
    print_opt "3" "Conserver"                 "Métadonnées préservées"                               "$([[ $def == 3 ]] && echo true)"
    ask_choice "Votre choix" "$def" "3"
    case "$REPLY" in
      1) STRIP_META="all" ;;
      2) STRIP_META="nodates" ;;
      3) STRIP_META=false ;;
    esac

    # Choix "Conserver" : rien à vérifier, on sort
    if [[ "$STRIP_META" == "false" ]]; then
      break
    fi

    # PDF : exiftool et qpdf recommandés, pas bloquants
    if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then
      local missing; missing=$(_missing_pdf_meta_tools)
      [[ -z "$missing" ]] && break
      echo ""
      warn "Outils manquants pour une suppression complète : ${missing}"
      echo -e "    ${DIM}Sans eux, le champ Producer (Ghostscript) ou d'anciennes valeurs peuvent rester.${RESET}"
      echo ""
      print_opt "1" "Installer maintenant"        "sudo apt install ${missing}"  "true"
      print_opt "2" "Continuer sans"              "Suppression partielle"
      print_opt "3" "Revenir au choix précédent"  ""
      ask_choice "Votre choix" "1" "3"
      case "$REPLY" in
        1)
          # shellcheck disable=SC2086
          if sudo apt install -y $missing; then success "Outils installés."; break; fi
          warn "Installation échouée."
          continue
          ;;
        2) break ;;
        3) continue ;;
      esac
    fi

    # JPEG sans exiftool : bloquant (exiftool indispensable pour JPEG)
    if [[ "$OUTPUT_FORMAT" == "jpeg" ]] && ! command -v exiftool &>/dev/null; then
      echo ""
      warn "exiftool est requis pour supprimer les métadonnées JPEG."
      echo -e "    ${DIM}Installez-le avec : ${BOLD}sudo apt install libimage-exiftool-perl${RESET}"
      echo ""
      print_opt "1" "Installer exiftool"         "sudo apt install libimage-exiftool-perl"  "true"
      print_opt "2" "Revenir au choix précédent" "Choisir une autre option ou Conserver"
      ask_choice "Votre choix" "1" "2"
      case "$REPLY" in
        1)
          if sudo apt install -y libimage-exiftool-perl; then success "exiftool installé."; break; fi
          warn "Installation échouée."
          continue
          ;;
        2) continue ;;
      esac
    else
      break
    fi
  done

  if [[ "$STRIP_META" != "false" ]]; then
    local _meta_msg; if [[ "$STRIP_META" == "all" ]]; then _meta_msg="tout supprimer"; else _meta_msg="supprimer sauf dates"; fi
    success "Métadonnées : ${_meta_msg}."
  fi
}

menu_ocr() {
  # Proposé seulement si le format de sortie est PDF
  [[ "$OUTPUT_FORMAT" != "pdf" ]] && return 0

  section "OCR — Texte sélectionnable"
  echo -e "    ${DIM}L'OCR analyse l'image et intègre une couche de texte invisible dans le PDF.${RESET}"
  echo -e "    ${DIM}Résultat : texte copié-collable, recherche Ctrl+F, lecture par les lecteurs d'écran.${RESET}"
  echo ""

  local def=2; if $OCR; then def=1; fi
  if ! command -v ocrmypdf &>/dev/null; then
    print_opt "1" "Activer l'OCR"   "Installe ocrmypdf automatiquement"  "$([[ $def == 1 ]] && echo true)"
  else
    print_opt "1" "Activer l'OCR"   "PDF consultable avec texte intégré"  "$([[ $def == 1 ]] && echo true)"
  fi
  print_opt "2" "Sans OCR"        "PDF image uniquement"  "$([[ $def == 2 ]] && echo true)"
  ask_choice "Votre choix" "$def" "2"

  OCR=false
  if [[ "$REPLY" == "1" ]]; then
    OCR=true
    if ! command -v ocrmypdf &>/dev/null; then
      info "Installation de ocrmypdf..."
      sudo apt install -y ocrmypdf || error "Échec de l'installation de ocrmypdf."
      success "ocrmypdf installé."
    fi
    echo ""
    echo -e "  ${BOLD}Langue du document${RESET}"
    echo -e "  ${DIM}Utilisez les codes ISO : fra (français), eng (anglais), deu (allemand), spa (espagnol)…${RESET}"
    echo -e "  ${DIM}Plusieurs langues possibles : fra+eng${RESET}"
    echo ""
    local ldef=4
    case "$OCR_LANG" in fra) ldef=1 ;; eng) ldef=2 ;; fra+eng) ldef=3 ;; esac
    print_opt "1" "Français"            "fra"      "$([[ $ldef == 1 ]] && echo true)"
    print_opt "2" "Anglais"             "eng"      "$([[ $ldef == 2 ]] && echo true)"
    print_opt "3" "Français + Anglais"  "fra+eng"  "$([[ $ldef == 3 ]] && echo true)"
    print_opt "4" "Autre"               "Saisir manuellement$([[ $ldef == 4 ]] && echo " (actuel : ${OCR_LANG})")"  "$([[ $ldef == 4 ]] && echo true)"
    ask_choice "Langue" "$ldef" "4"
    case "$REPLY" in
      1) OCR_LANG="fra" ;;
      2) OCR_LANG="eng" ;;
      3) OCR_LANG="fra+eng" ;;
      4)
        while true; do
          ask "Code(s) de langue" "$OCR_LANG"
          if [[ "$REPLY" =~ ^[a-z_]+(\+[a-z_]+)*$ ]]; then break; fi
          warn "Format attendu : codes en minuscules séparés par + (ex : fra+deu)."
        done
        OCR_LANG="$REPLY"
        ;;
    esac

    # Vérifier que les données Tesseract pour chaque langue sont installées
    local missing_langs=()
    local available_langs
    available_langs=$(tesseract --list-langs 2>/dev/null | tail -n +2)
    local lang
    for lang in ${OCR_LANG//+/ }; do
      if ! echo "$available_langs" | grep -qx "$lang"; then
        missing_langs+=("tesseract-ocr-${lang}")
      fi
    done
    if [[ ${#missing_langs[@]} -gt 0 ]]; then
      warn "Données de langue Tesseract manquantes : ${missing_langs[*]}"
      echo -ne "  ${BOLD}→${RESET} Installer maintenant ? ${DIM}[O/n]${RESET} : "
      read -r _tess_ans
      if [[ "${_tess_ans,,}" != "n" ]]; then
        sudo apt install -y "${missing_langs[@]}" \
          || error "Échec de l'installation des données de langue."
        success "Données de langue installées."
      else
        warn "Sans les données de langue, l'OCR ne fonctionnera pas pour : ${OCR_LANG}"
      fi
    fi

    success "OCR activé — langue : ${OCR_LANG}"
  fi
}

# =============================================================================
#  OCR
# =============================================================================

do_ocr() {
  local infile="$1"
  local outfile="$2"

  info "OCR en cours (langue : ${OCR_LANG})..."

  local ocr_err
  ocr_err=$(mktemp)
  if ! ocrmypdf \
      --language "$OCR_LANG" \
      --output-type pdf \
      --skip-text \
      --optimize 1 \
      "$infile" "$outfile" 2>"$ocr_err"; then
    local msg; msg=$(cat "$ocr_err")
    rm -f "$ocr_err"
    warn "OCR échoué : ${msg:-erreur inconnue}\n  Le PDF sans OCR est conservé."
    cp "$infile" "$outfile"
    return 0
  fi
  rm -f "$ocr_err"

  local size_before size_after
  size_before=$(du -sh "$infile" | cut -f1)
  size_after=$(du -sh "$outfile" | cut -f1)
  success "OCR terminé : ${size_before} → ${size_after}"
  return 0
}

do_strip_meta() {
  local infile="$1"
  local outfile="$2"
  # STRIP_META global : all = tout vider | nodates = tout sauf CreationDate/ModDate

  info "Suppression des métadonnées (mode : ${STRIP_META})..."

  local fmt="${infile##*.}"; fmt="${fmt,,}"

  # =========================================================================
  # JPEG : exiftool uniquement (GS ne gère pas les JPEG)
  # =========================================================================
  if [[ "$fmt" == "jpg" ]] || [[ "$fmt" == "jpeg" ]]; then
    if ! command -v exiftool &>/dev/null; then
      warn "exiftool introuvable — métadonnées JPEG conservées."
      cp "$infile" "$outfile"
      return 0
    fi
    cp "$infile" "$outfile"
    if [[ "$STRIP_META" == "all" ]]; then
      exiftool -q -all= -overwrite_original "$outfile" 2>/dev/null \
        || warn "exiftool : suppression partielle."
    else
      # nodates : supprimer tout sauf les dates
      # -all= vide tout, -tagsFromFile @ recopie ensuite les dates d'origine
      exiftool -q -all= -tagsFromFile @ \
        -DateTimeOriginal -CreateDate -ModifyDate \
        -overwrite_original "$outfile" 2>/dev/null \
        || warn "exiftool : suppression partielle."
    fi
    success "Métadonnées JPEG supprimées."
    return 0
  fi

  # =========================================================================
  # PDF : Ghostscript (DocInfo) + exiftool optionnel (XMP + Producer GS)
  # =========================================================================
  local pdfmarks
  pdfmarks=$(mktemp --suffix=.pdfmarks)

  if [[ "$STRIP_META" == "all" ]]; then
    cat > "$pdfmarks" <<'PDFMARKS'
[ /Title ()
  /Author ()
  /Subject ()
  /Creator ()
  /Keywords ()
  /Producer ()
  /CreationDate ()
  /ModDate ()
  /Trapped /False
  /DOCINFO
pdfmark
PDFMARKS
  else
    # nodates : conserver CreationDate et ModDate
    cat > "$pdfmarks" <<'PDFMARKS'
[ /Title ()
  /Author ()
  /Subject ()
  /Creator ()
  /Keywords ()
  /Producer ()
  /Trapped /False
  /DOCINFO
pdfmark
PDFMARKS
  fi

  local gs_out
  gs_out=$(mktemp --suffix=.pdf)
  if gs -q -dNOPAUSE -dBATCH \
      -sDEVICE=pdfwrite \
      -dFastWebView=false \
      -sOutputFile="$gs_out" \
      "$infile" "$pdfmarks" 2>/dev/null; then
    mv "$gs_out" "$outfile"
  else
    rm -f "$gs_out"
    warn "Suppression des métadonnées (GS) échouée, fichier conservé tel quel."
    cp "$infile" "$outfile"
    rm -f "$pdfmarks"
    return 0
  fi
  rm -f "$pdfmarks"

  # Passage 2 : exiftool — supprime Producer GS et résidus XMP (optionnel)
  if command -v exiftool &>/dev/null; then
    if [[ "$STRIP_META" == "all" ]]; then
      exiftool -q -all= -overwrite_original "$outfile" 2>/dev/null \
        || warn "exiftool : suppression partielle des métadonnées XMP."
    else
      # nodates : exclure les tags de date de la suppression
      # nodates : -all= vide tout le dictionnaire PDF (les exclusions --Tag n'y
      # suffisent pas), -tagsFromFile @ recopie ensuite les dates
      exiftool -q -all= -tagsFromFile @ \
        -PDF:CreateDate -PDF:ModifyDate -XMP:CreateDate -XMP:ModifyDate \
        -overwrite_original "$outfile" 2>/dev/null \
        || warn "exiftool : suppression partielle des métadonnées XMP."
    fi
  fi

  # Passage 3 : qpdf — exiftool modifie le PDF par ajout (les anciennes valeurs
  # restent dans le fichier et « exiftool -PDF-update:all= » les restaure).
  # qpdf réécrit le fichier avec les seuls objets utilisés : elles disparaissent.
  if command -v qpdf &>/dev/null; then
    local qpdf_out
    qpdf_out=$(mktemp --suffix=.pdf)
    # Code 3 = avertissements seulement : le fichier produit est valide
    local rc=0
    qpdf --object-streams=generate "$outfile" "$qpdf_out" 2>/dev/null || rc=$?
    if [[ $rc -eq 0 || $rc -eq 3 ]] && [[ -s "$qpdf_out" ]]; then
      mv "$qpdf_out" "$outfile"
    else
      rm -f "$qpdf_out"
      warn "qpdf : réécriture échouée, d'anciennes valeurs peuvent rester récupérables."
    fi
  elif command -v exiftool &>/dev/null; then
    warn "qpdf absent : les anciennes métadonnées restent récupérables dans le fichier."
    echo -e "    ${DIM}Pour une suppression définitive : ${BOLD}sudo apt install qpdf${RESET}"
  fi

  success "Métadonnées PDF supprimées."
}

do_compress() {
  local infile="$1"
  local outfile="$2"

  info "Compression PDF (ghostscript)..."

  # ebook = ~150 dpi, printer = ~300 dpi, prepress = ~300 dpi haute fidélité
  local gs_preset="printer"
  if [[ "$RESOLUTION" -le 150 ]]; then gs_preset="ebook"; fi

  gs -q -dNOPAUSE -dBATCH \
    -sDEVICE=pdfwrite \
    -dPDFSETTINGS=/"$gs_preset" \
    -sOutputFile="$outfile" \
    "$infile" 2>/dev/null \
    || { warn "Compression ghostscript échouée, PDF non compressé conservé"; cp "$infile" "$outfile"; }

  local size_before size_after
  size_before=$(du -sh "$infile" | cut -f1)
  size_after=$(du -sh "$outfile" | cut -f1)
  success "Compression : ${size_before} → ${size_after}"
}

# =============================================================================
#  SCAN MULTI-PAGES
# =============================================================================

# Extension des pages traitées : JPEG en sortie JPEG ; sinon MIFF, format
# interne sans perte qui conserve la résolution, assemblé ensuite en un seul
# PDF (assembler des PDF avec convert les re-rastériserait à 72 dpi).
_page_ext() {
  if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then echo "jpg"; else echo "miff"; fi
}

# Scanne puis traite une page ; ajoute le résultat à PAGES
_scan_page() {
  local tmpdir="$1" num="$2"
  local scan_tmp="${tmpdir}/page_${num}.pnm"
  local proc_tmp="${tmpdir}/page_${num}_processed.$(_page_ext)"
  do_scan "$scan_tmp"
  do_process "$scan_tmp" "$proc_tmp"
  PAGES+=("$proc_tmp")
}

do_multi_page() {
  local tmpdir="$1"
  local page_num=0

  if [[ "$MULTI_PAGE_MODE" == "adf" ]]; then
    do_scan_adf "$tmpdir"
  elif [[ "$MULTI_PAGE_MODE" == "auto" ]]; then
    while true; do
      page_num=$(( page_num + 1 ))
      echo ""
      echo -e "${BOLD}--- Page ${page_num} ---${RESET}"
      _scan_page "$tmpdir" "$page_num"

      echo -e "\n  ${DIM}Pour continuer, placez la page suivante dans le scanner avant de répondre.${RESET}"
      echo -ne "  ${BOLD}→${RESET} Scanner une autre page ? ${DIM}[O/n]${RESET} : "
      read -r _more
      if [[ "${_more,,}" == "n" ]]; then break; fi
    done
  else
    for (( i=1; i<=NB_PAGES; i++ )); do
      echo ""
      echo -e "${BOLD}--- Page ${i}/${NB_PAGES} ---${RESET}"
      _scan_page "$tmpdir" "$i"

      if [[ $i -lt $NB_PAGES ]]; then
        echo -e "\n  ${YELLOW}Placez la page suivante dans le scanner, puis appuyez sur ENTRÉE...${RESET}"
        read -r
      fi
    done
  fi
}

# =============================================================================
#  TRAITEMENT PRINCIPAL (partagé entre mode CLI et interactif)
# =============================================================================

main_process() {
  # Extension selon le format de sortie
  local ext; if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then ext="jpg"; else ext="pdf"; fi

  resolve_output
  confirm_overwrite

  SCAN_TMPDIR=$(mktemp -d /tmp/scan-doc-XXXXXX)
  local tmpdir="$SCAN_TMPDIR"
  if $KEEP_TEMP; then info "Fichiers temporaires dans : $tmpdir"; fi
  if ! $KEEP_TEMP; then trap 'rm -rf "$SCAN_TMPDIR"' EXIT; fi

  PAGES=()
  if [[ -z "$INPUT_FILE" ]]; then prepare_scanner; fi

  # --- Étapes 1 et 2 : source (scan ou fichier existant) + post-traitement ---
  if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || error "Fichier introuvable : $INPUT_FILE"
    info "Source : $INPUT_FILE"

    local sources=()
    if [[ "${INPUT_FILE,,}" == *.pdf ]]; then
      info "Conversion PDF → PNM (${RESOLUTION} dpi, ${DEPTH}-bit)..."
      # %03d : une image par page, numérotée dans l'ordre
      convert -density "$RESOLUTION" -depth "$DEPTH" "$INPUT_FILE" "${tmpdir}/source-%03d.pnm" \
        || error "Échec de la conversion PDF"
      sources=("${tmpdir}"/source-*.pnm)
      [[ -f "${sources[0]}" ]] || error "Aucune page extraite de : $INPUT_FILE"
      if [[ ${#sources[@]} -gt 1 ]]; then info "${#sources[@]} pages détectées."; fi
    else
      sources=("$INPUT_FILE")
    fi

    local n=0 src
    for src in "${sources[@]}"; do
      n=$(( n + 1 ))
      local proc_tmp="${tmpdir}/page_${n}_processed.$(_page_ext)"
      do_process "$src" "$proc_tmp"
      PAGES+=("$proc_tmp")
    done

  elif $MULTI_PAGE; then
    do_multi_page "$tmpdir"

  else
    _scan_page "$tmpdir" 1
  fi

  # --- Étape 3 : Finalisation -----------------------------------------------
  if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    _finalize_jpeg "$tmpdir"
    return
  fi

  info "Création du PDF (${#PAGES[@]} page(s))..."
  local merged="${tmpdir}/merged.pdf"
  local pdf_args=()
  if [[ "$MODE" == "bw" ]]; then
    # Image 1 bit compressée en CCITT Group4 (format fax) : PDF noir et
    # blanc bien plus léger, sans perte
    pdf_args=("-type" "bilevel" "-compress" "Group4")
  fi
  convert "${PAGES[@]}" "${pdf_args[@]}" "$merged" || error "Échec de la création du PDF"

  # Le noir et blanc est déjà en Group4 : Ghostscript ne ferait que le ré-encoder
  # en plus gros
  local compress=$COMPRESS
  if $compress && [[ "$MODE" == "bw" ]]; then
    info "Noir et blanc déjà compressé en Group4 : compression Ghostscript inutile."
    compress=false
  fi

  if $OCR; then
    local pre_ocr="${tmpdir}/pre_ocr.pdf"
    if $compress; then
      do_compress "$merged" "$pre_ocr"
    else
      cp "$merged" "$pre_ocr"
    fi
    do_ocr "$pre_ocr" "$OUTPUT"
  elif $compress; then
    do_compress "$merged" "$OUTPUT"
  else
    cp "$merged" "$OUTPUT"
  fi

  if [[ "$STRIP_META" != "false" ]]; then
    local pre_strip="${tmpdir}/pre_strip.pdf"
    mv "$OUTPUT" "$pre_strip"
    do_strip_meta "$pre_strip" "$OUTPUT"
  fi

  _print_done
}

# Sortie JPEG : un fichier pour une page, nom_001.jpg, nom_002.jpg… sinon
_finalize_jpeg() {
  local tmpdir="$1"
  local total="${#PAGES[@]}"

  if [[ $total -eq 1 ]]; then
    cp "${PAGES[0]}" "$OUTPUT"
    if [[ "$STRIP_META" != "false" ]]; then
      local stripped_jpg="${tmpdir}/stripped.jpg"
      do_strip_meta "$OUTPUT" "$stripped_jpg"
      mv "$stripped_jpg" "$OUTPUT"
    fi
    _print_done
    return
  fi

  local base="${OUTPUT%.jpg}"
  local idx=1 f
  for f in "${PAGES[@]}"; do
    local dest
    printf -v dest "%s_%03d.jpg" "$base" "$idx"
    cp "$f" "$dest"
    if [[ "$STRIP_META" != "false" ]]; then
      local stripped_jpg="${tmpdir}/stripped_${idx}.jpg"
      do_strip_meta "$dest" "$stripped_jpg"
      mv "$stripped_jpg" "$dest"
    fi
    success "Page ${idx} → ${dest}"
    idx=$(( idx + 1 ))
  done
  local last; printf -v last "%s_%03d.jpg" "$base" "$total"
  echo ""
  echo -e "${GREEN}${BOLD}✓ Terminé !${RESET}"
  echo -e "  ${total} fichier(s) JPEG : ${BOLD}${base}_001.jpg${RESET} … ${BOLD}${last}${RESET}"
  echo ""
  if $OPEN_RESULT; then _open_result "${base}_001.jpg"; fi
}

_print_done() {
  local final_size
  final_size=$(du -sh "$OUTPUT" | cut -f1)
  echo ""
  echo -e "${GREEN}${BOLD}✓ Terminé !${RESET}"
  echo -e "  Fichier : ${BOLD}${OUTPUT}${RESET}  (${final_size})"
  echo ""
  if $OPEN_RESULT; then _open_result "$OUTPUT"; fi
}

# =============================================================================
#  POINT D'ENTRÉE
# =============================================================================

if [[ $# -eq 0 ]]; then
  # Aucun argument → mode interactif avec menus guidés
  run_interactive
elif $LIST_ONLY; then
  list_devices
elif $DIAGNOSTIC; then
  run_diagnostic
else
  # Arguments CLI → mode direct (comportement d'origine)
  validate_options
  check_deps
  main_process
fi