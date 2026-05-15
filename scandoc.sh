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
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; DIM='\033[2m'
BLUE='\033[0;34m'

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
MULTI_PAGE_MODE="fixed" # Mode multi-pages : fixed (nombre connu) | auto (continu jusqu'à stop)
MERGED_PDF=""           # Chemin du PDF assemblé (rempli par do_multi_page)
KEEP_TEMP=false         # Garder les fichiers temporaires (debug)
COMPRESS=true           # Compresser le PDF final avec ghostscript
DEPTH=8                 # Profondeur de couleur (8=standard, 16=haute fidélité)
OUTPUT_FORMAT="pdf"     # Format de sortie : pdf | jpeg
JPEG_QUALITY=85         # Qualité JPEG (1-100, 85=bon compromis qualité/taille)
MULTI_PAGE_FILES=()     # Chemins des pages traitées en mode multi-pages JPEG
OCR=false               # Activer l'OCR (texte sélectionnable) avec ocrmypdf
OCR_LANG="fra+eng"      # Langue(s) OCR : fra, eng, deu, spa... (séparer par +)
STRIP_META=false        # Métadonnées : false | all (tout supprimer) | nodates (tout sauf dates)
SCAN_TMPDIR=""          # Répertoire temporaire de travail (global pour le trap EXIT)

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
    error "Dépendances manquantes : ${missing[*]}\n  → sudo apt install ${missing[*]}"
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
    printf "    ${BOLD}[%s]${RESET} %-28s ${DIM}%s${RESET}  ${GREEN}★ recommandé${RESET}\n" \
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

# =============================================================================
#  MENUS INTERACTIFS
# =============================================================================

menu_main() {
  section "Que souhaitez-vous faire ?"
  print_opt "1" "Scanner un document"              "Utilise le scanner connecté au système"          "true"
  print_opt "2" "Traiter un fichier existant"      "Image ou PDF déjà présent sur le disque"
  print_opt "3" "Scanner plusieurs pages"          "Pause entre chaque page, PDF assemblé automatiquement"
  print_opt "4" "Lister les scanners disponibles"  "Affiche les scanners détectés par SANE"
  print_opt "5" "Quitter"                          ""
  ask_choice "Votre choix" "1" "5"
}

menu_input_file() {
  section "Fichier source à traiter"
  echo -e "    ${DIM}Formats supportés : JPG, PNG, TIFF, BMP, PNM, PDF…${RESET}"
  echo ""
  ask "Chemin complet du fichier" ""
  INPUT_FILE="$REPLY"
  [[ -z "$INPUT_FILE" ]] && error "Aucun fichier spécifié."
  [[ -f "$INPUT_FILE" ]] || error "Fichier introuvable : $INPUT_FILE"
  success "Fichier sélectionné : $INPUT_FILE"
}

menu_device() {
  section "Scanner à utiliser"
  print_opt "1" "Auto-détection (conseillé)"  "Laisse SANE choisir le scanner disponible"  "true"
  print_opt "2" "Saisir manuellement"          "Entrer l'identifiant SANE du scanner"
  ask_choice "Votre choix" "1" "2"

  if [[ "$REPLY" == "2" ]]; then
    echo ""
    info "Scanners détectés sur ce système :"
    scanimage -L 2>/dev/null || warn "Aucun scanner détecté (vérifiez la connexion USB/réseau)."
    echo ""
    ask "Identifiant du scanner (ex: brother5:net1;dev0)" ""
    if [[ -n "$REPLY" ]]; then DEVICE="$REPLY"; fi
  fi
}

menu_format() {
  section "Format du document"
  echo -e "    ${DIM}Définit la zone de scan. En mode auto, le scanner scanne en plein format${RESET}"
  echo -e "    ${DIM}puis les bandes noires sont supprimées automatiquement.${RESET}"
  echo ""
  print_opt "1" "Auto (détection automatique)"  "Scan pleine zone + recadrage intelligent des bords"  "true"
  print_opt "2" "A4         210 × 297 mm"        "Standard européen — lettre, facture, contrat"
  print_opt "3" "A5         148 × 210 mm"        "Demi-format A4 — livret, carnet"
  print_opt "4" "Letter     216 × 279 mm"        "Format américain US Letter"
  print_opt "5" "Legal      216 × 356 mm"        "Format américain US Legal (plus long)"
  print_opt "6" "Personnalisé"                   "Saisir largeur et hauteur en millimètres"
  ask_choice "Votre choix" "1" "6"

  case "$REPLY" in
    1) PAPER_FORMAT="auto" ;;
    2) PAPER_FORMAT="A4" ;;
    3) PAPER_FORMAT="A5" ;;
    4) PAPER_FORMAT="Letter" ;;
    5) PAPER_FORMAT="Legal" ;;
    6)
      ask "Largeur en mm" "210"
      local w="$REPLY"
      ask "Hauteur en mm" "297"
      PAPER_FORMAT="custom:${w}x${REPLY}"
      ;;
  esac
  success "Format : ${PAPER_FORMAT}"
}

menu_resolution() {
  section "Résolution de scan"
  echo -e "    ${DIM}Plus la résolution est élevée, plus l'image est nette — mais le fichier est plus lourd.${RESET}"
  echo ""
  print_opt "1" "150 dpi  — Rapide / Léger"    "Emails, documents simples              ~0.5 Mo"
  print_opt "2" "300 dpi  — Standard"           "Usage quotidien, bonne qualité         ~2 Mo"   "true"
  print_opt "3" "600 dpi  — Haute qualité"      "Contrats, photos, archivage            ~8 Mo"
  print_opt "4" "Valeur personnalisée"           "Saisir un nombre en dpi"
  ask_choice "Votre choix" "2" "4"

  case "$REPLY" in
    1) RESOLUTION=150 ;;
    2) RESOLUTION=300 ;;
    3) RESOLUTION=600 ;;
    4)
      ask "Résolution en dpi" "300"
      [[ "$REPLY" =~ ^[0-9]+$ ]] || error "Valeur invalide : $REPLY"
      RESOLUTION="$REPLY"
      ;;
  esac
  success "Résolution : ${RESOLUTION} dpi"
}

menu_mode() {
  section "Mode de traitement"
  echo -e "    ${DIM}Détermine le filtre appliqué à l'image après le scan.${RESET}"
  echo ""
  print_opt "1" "clean  — Nettoyage fond gris"    "Blanchit le fond, préserve couleurs  → lettres, factures" "true"
  print_opt "2" "bw     — Noir et blanc pur"       "Texte noir sur fond blanc, très léger → formulaires, reçus"
  print_opt "3" "color  — Normalisation couleurs"  "Booste les couleurs → photos, plans, documents colorés"
  print_opt "4" "scan   — Brut (sans retouche)"    "Pas de traitement, PDF direct du scanner"
  ask_choice "Votre choix" "1" "4"

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
  ask_choice "Votre choix" "1" "2"

  if [[ "$REPLY" == "1" ]]; then
    MULTI_PAGE_MODE="fixed"
    echo ""
    ask "Nombre de pages à scanner" "$NB_PAGES"
    if [[ ! "$REPLY" =~ ^[0-9]+$ ]] || [[ "$REPLY" -lt 1 ]]; then
      error "Nombre de pages invalide : $REPLY"
    fi
    NB_PAGES="$REPLY"
    success "$NB_PAGES page(s) configurée(s)."
  else
    MULTI_PAGE_MODE="auto"
    success "Mode continu : vous serez invité après chaque page."
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
      ask "Seuil (0-100)" "$WHITE_THRESH"
      WHITE_THRESH="$REPLY"
      echo ""
      ;;
    bw)
      echo -e "  ${BOLD}Seuil de binarisation${RESET}  ${DIM}(mode bw)${RESET}"
      echo -e "  ${DIM}En dessous de ce seuil → noir pur. Au-dessus → blanc pur.${RESET}"
      echo -e "  ${DIM}  ↑ Monter si le fond gris persiste   ↓ Descendre si le texte disparaît${RESET}"
      ask "Seuil (0-100)" "$THRESHOLD"
      THRESHOLD="$REPLY"
      echo ""
      echo -e "  ${BOLD}Flou anti-bruit${RESET}"
      echo -e "  ${DIM}Lisse légèrement l'image avant la binarisation pour réduire le grain.${RESET}"
      echo -e "  ${DIM}  0 = désactivé   1 = léger   2 = moyen (recommandé pour vieux documents)${RESET}"
      ask "Rayon de flou (0-3)" "$BLUR"
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
    print_opt "1" "Activée (recommandé)"  "Réduit significativement la taille du fichier"  "true"
    print_opt "2" "Désactivée"            "PDF non optimisé (plus volumineux)"
    ask_choice "Compression" "1" "2"
    if [[ "$REPLY" == "2" ]]; then COMPRESS=false; fi
  else
    echo -e "  ${BOLD}Qualité JPEG${RESET}"
    echo -e "  ${DIM}Plus la valeur est haute, meilleure est la qualité — mais le fichier est plus lourd.${RESET}"
    echo -e "  ${DIM}  75 = léger   85 = bon compromis   95 = haute fidélité${RESET}"
    echo ""
    ask "Qualité (1-100)" "$JPEG_QUALITY"
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [[ "$REPLY" -ge 1 ]] && [[ "$REPLY" -le 100 ]]; then
      JPEG_QUALITY="$REPLY"
    else
      warn "Valeur invalide, qualité conservée à ${JPEG_QUALITY}."
    fi
  fi

  success "Options avancées appliquées."
}

menu_output() {
  section "Format et fichier de sortie"

  echo -e "  ${BOLD}Format de sortie${RESET}"
  echo ""
  print_opt "1" "PDF  (recommandé)"   "Un seul fichier, idéal pour documents et archivage"  "true"
  print_opt "2" "JPEG"                "Image(s) — pratique pour envoyer par email ou partager"
  ask_choice "Votre choix" "1" "2"
  if [[ "$REPLY" == "2" ]]; then OUTPUT_FORMAT="jpeg"; else OUTPUT_FORMAT="pdf"; fi
  echo ""

  local ext; if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then ext="jpg"; else ext="pdf"; fi
  local default_name="scan_$(date +%Y%m%d_%H%M%S).${ext}"
  if $MULTI_PAGE && [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    echo -e "    ${DIM}Mode multi-pages JPEG : les fichiers seront nommés nom_001.jpg, nom_002.jpg…${RESET}"
  else
    echo -e "    ${DIM}Nom du fichier à créer. Laissez vide pour un nom généré automatiquement.${RESET}"
  fi
  echo ""
  ask "Nom du fichier (.${ext})" "$default_name"
  OUTPUT="${REPLY%.*}.${ext}"
  success "Format : ${OUTPUT_FORMAT^^}  —  Sortie : $OUTPUT"
}

menu_summary() {
  section "Récapitulatif — Prêt à démarrer"
  printf "    %-22s ${CYAN}%s${RESET}\n" "Résolution :"   "${RESOLUTION} dpi"
  printf "    %-22s ${CYAN}%s${RESET}\n" "Mode :"         "$MODE"
  printf "    %-22s ${CYAN}%s${RESET}\n" "Sortie :"       "$OUTPUT"
  if $MULTI_PAGE; then
    if [[ "$MULTI_PAGE_MODE" == "auto" ]]; then
      printf "    %-22s ${CYAN}%s${RESET}\n" "Pages :" "mode continu (au fil de l'eau)"
    else
      printf "    %-22s ${CYAN}%s${RESET}\n" "Pages :" "$NB_PAGES"
    fi
  fi
  if [[ -n "$INPUT_FILE" ]]; then printf "    %-22s ${CYAN}%s${RESET}\n" "Source :" "$INPUT_FILE"; fi
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
    4)  list_devices ;;
    5)  echo "Au revoir !"; exit 0 ;;
  esac

  menu_output

  if [[ "$OUTPUT_FORMAT" == "pdf" ]]; then menu_ocr; fi
  menu_meta

  echo ""
  echo -ne "  ${BOLD}→${RESET} Configurer les options avancées ? ${DIM}[o/N]${RESET} : "
  read -r _adv
  if [[ "${_adv,,}" == "o" ]]; then menu_advanced; fi

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
  -k             Garder les fichiers temporaires
  -C             Désactiver la compression ghostscript
  -l             Lister les scanners disponibles
  -h             Afficher cette aide

${BOLD}EXEMPLES${RESET}
  $(basename "$0") -o contrat.pdf
  $(basename "$0") -r 600 -m color -o photo.pdf
  $(basename "$0") -f scan_existant.jpg -m bw -t 60
  $(basename "$0") -p -n 5 -o dossier_complet.pdf
EOF
  exit 0
}

list_devices() {
  info "Recherche des scanners disponibles..."
  scanimage -L 2>/dev/null || error "scanimage introuvable — installe sane-utils"
  exit 0
}

# =============================================================================
#  PARSING DES OPTIONS (mode CLI)
# =============================================================================

while getopts "r:m:o:f:t:w:b:d:F:O:L:n:pkCRMlh" opt; do
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
    k) KEEP_TEMP=true ;;
    C) COMPRESS=false ;;
    R) OCR=true ;;
    M) STRIP_META=all ;;
    l) list_devices ;;
    h) usage ;;
    *) usage ;;
  esac
done

# =============================================================================
#  SCAN
# =============================================================================

# Retourne les options -x / -y pour scanimage selon PAPER_FORMAT
# En mode "auto" : pas de contrainte, le scanner utilise sa plage maximale
_paper_size_opts() {
  case "$PAPER_FORMAT" in
    auto)   echo "" ;;
    A4)     echo "-x 210 -y 297" ;;
    A5)     echo "-x 148 -y 210" ;;
    Letter) echo "-x 215.9 -y 279.4" ;;
    Legal)  echo "-x 215.9 -y 355.6" ;;
    custom:*)
      local dims="${PAPER_FORMAT#custom:}"
      local w="${dims%x*}"
      local h="${dims#*x}"
      echo "-x $w -y $h"
      ;;
    *) echo "" ;;
  esac
  return 0
}

do_scan() {
  local outfile="$1"
  local device_opt=""
  if [[ -n "$DEVICE" ]]; then device_opt="--device-name=$DEVICE"; fi

  # Mode couleur scanimage selon le mode de traitement
  local scan_mode_opt
  case "$MODE" in
    bw) scan_mode_opt="--mode=Gray" ;;
    *)  scan_mode_opt="--mode=Color" ;;
  esac

  # Dimensions de la zone de scan
  local size_opts
  size_opts=$(_paper_size_opts)

  info "Scan en cours (${RESOLUTION} dpi, format ${PAPER_FORMAT}, mode ${MODE})..."

  local scan_err
  scan_err=$(mktemp)
  # shellcheck disable=SC2086
  if ! scanimage \
      $device_opt \
      $scan_mode_opt \
      $size_opts \
      --format="pnm" \
      --resolution="$RESOLUTION" \
      > "$outfile" 2>"$scan_err"; then
    local msg
    msg=$(cat "$scan_err")
    rm -f "$scan_err"
    error "Échec du scan : ${msg:-erreur inconnue}\n  → Vérifiez que le document est chargé et le scanner prêt."
  fi
  rm -f "$scan_err"

  # En mode auto : recadrage automatique des bandes noires/vides en bordure
  if [[ "$PAPER_FORMAT" == "auto" ]]; then
    info "Recadrage automatique des bords..."
    local trimmed
    trimmed=$(mktemp --suffix=.pnm)
    if convert "$outfile" -fuzz 8% -trim +repage "$trimmed" 2>/dev/null; then
      mv "$trimmed" "$outfile"
      success "Recadrage effectué."
    else
      rm -f "$trimmed"
      warn "Recadrage automatique échoué, image conservée telle quelle."
    fi
  fi

  success "Scan terminé → $outfile"
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

  # Qualité JPEG si applicable
  if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    im_args+=("-quality" "$JPEG_QUALITY")
  fi

  convert "$infile" "${im_args[@]}" "$outfile" \
    || error "Échec du post-traitement ImageMagick"

  success "Post-traitement terminé → $outfile"
}

menu_meta() {
  local _needs_exiftool=false
  if [[ "$OUTPUT_FORMAT" == "jpeg" ]] && ! command -v exiftool &>/dev/null; then
    _needs_exiftool=true
  fi

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
    print_opt "1" "Supprimer tout"            "Outils, dates, tous les champs vidés"
    print_opt "2" "Supprimer sauf les dates"  "Vide l'outil source, conserve CreationDate/ModDate"
    print_opt "3" "Conserver"                 "Métadonnées préservées"  "true"
    ask_choice "Votre choix" "3" "3"
    case "$REPLY" in
      1) STRIP_META="all" ;;
      2) STRIP_META="nodates" ;;
      3) STRIP_META=false ;;
    esac

    # Choix "Conserver" : rien à vérifier, on sort
    if [[ "$STRIP_META" == "false" ]]; then
      break
    fi

    # PDF sans exiftool : simple avertissement, pas bloquant (GS fait quand même le travail)
    if [[ "$OUTPUT_FORMAT" == "pdf" ]] && ! command -v exiftool &>/dev/null; then
      echo ""
      warn "exiftool non installé : le champ Producer (Ghostscript) restera présent."
      echo -e "    ${DIM}Pour une suppression complète : ${BOLD}sudo apt install libimage-exiftool-perl${RESET}"
      echo ""
      print_opt "1" "Continuer sans exiftool"   "Producer GS restera, le reste sera supprimé"  "true"
      print_opt "2" "Installer exiftool d'abord" "sudo apt install libimage-exiftool-perl"
      print_opt "3" "Revenir au choix précédent" ""
      ask_choice "Votre choix" "1" "3"
      case "$REPLY" in
        1) break ;;
        2)
          sudo apt install -y libimage-exiftool-perl \
            && { success "exiftool installé."; break; } \
            || { warn "Installation échouée."; continue; }
          ;;
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
          sudo apt install -y libimage-exiftool-perl \
            && { success "exiftool installé."; break; } \
            || { warn "Installation échouée."; continue; }
          ;;
        2) continue ;;
      esac
    else
      # Tout est OK
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

  if ! command -v ocrmypdf &>/dev/null; then
    print_opt "1" "Activer l'OCR"   "Installe ocrmypdf automatiquement"
    print_opt "2" "Sans OCR"        "PDF image uniquement"  "true"
  else
    print_opt "1" "Activer l'OCR"   "PDF consultable avec texte intégré"
    print_opt "2" "Sans OCR"        "PDF image uniquement"  "true"
  fi
  ask_choice "Votre choix" "2" "2"

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
    print_opt "1" "Français"            "fra"        "true"
    print_opt "2" "Anglais"             "eng"
    print_opt "3" "Français + Anglais"  "fra+eng"
    print_opt "4" "Autre"               "Saisir manuellement"
    ask_choice "Langue" "1" "4"
    case "$REPLY" in
      1) OCR_LANG="fra" ;;
      2) OCR_LANG="eng" ;;
      3) OCR_LANG="fra+eng" ;;
      4)
        ask "Code(s) de langue" "fra"
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
      exiftool -q -all= \
        --DateTimeOriginal --CreateDate --ModifyDate --DateTime \
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
      exiftool -q -all= \
        --CreateDate --ModifyDate --DateTime \
        --XMP:CreateDate --XMP:ModifyDate --XMP:MetadataDate \
        -overwrite_original "$outfile" 2>/dev/null \
        || warn "exiftool : suppression partielle des métadonnées XMP."
    fi
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

do_multi_page() {
  local tmpdir="$1"
  local pages=()
  local page_num=0
  local proc_ext; if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then proc_ext="jpg"; else proc_ext="pdf"; fi

  if [[ "$MULTI_PAGE_MODE" == "auto" ]]; then
    while true; do
      page_num=$(( page_num + 1 ))
      echo ""
      echo -e "${BOLD}--- Page ${page_num} ---${RESET}"
      local scan_tmp="${tmpdir}/page_${page_num}.pnm"
      local proc_tmp="${tmpdir}/page_${page_num}_processed.${proc_ext}"

      do_scan "$scan_tmp"
      do_process "$scan_tmp" "$proc_tmp"
      pages+=("$proc_tmp")

      echo -ne "\n  ${BOLD}→${RESET} Scanner une autre page ? ${DIM}[O/n]${RESET} : "
      read -r _more
      if [[ "${_more,,}" == "n" ]]; then break; fi
      echo -e "  ${DIM}Placez la page suivante dans le scanner, puis appuyez sur Entrée pour continuer...${RESET}"
    done
  else
    for (( i=1; i<=NB_PAGES; i++ )); do
      echo ""
      echo -e "${BOLD}--- Page ${i}/${NB_PAGES} ---${RESET}"
      local scan_tmp="${tmpdir}/page_${i}.pnm"
      local proc_tmp="${tmpdir}/page_${i}_processed.${proc_ext}"

      do_scan "$scan_tmp"
      do_process "$scan_tmp" "$proc_tmp"
      pages+=("$proc_tmp")

      if [[ $i -lt $NB_PAGES ]]; then
        echo -e "\n  ${YELLOW}Placez la page suivante dans le scanner, puis appuyez sur ENTRÉE...${RESET}"
        read -r
      fi
    done
    page_num=$NB_PAGES
  fi

  if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    MULTI_PAGE_FILES=("${pages[@]}")
    MERGED_PDF=""
  else
    info "Assemblage des ${page_num} pages..."
    convert "${pages[@]}" "${tmpdir}/merged.pdf" \
      || error "Échec de l'assemblage des pages"
    MERGED_PDF="${tmpdir}/merged.pdf"
  fi
}

# =============================================================================
#  TRAITEMENT PRINCIPAL (partagé entre mode CLI et interactif)
# =============================================================================

main_process() {
  # Extension selon le format de sortie
  local ext; if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then ext="jpg"; else ext="pdf"; fi

  if [[ -z "$OUTPUT" ]]; then OUTPUT="scan_$(date +%Y%m%d_%H%M%S).${ext}"; fi
  OUTPUT="${OUTPUT%.*}.${ext}"

  SCAN_TMPDIR=$(mktemp -d /tmp/scan-doc-XXXXXX)
  local tmpdir="$SCAN_TMPDIR"
  if $KEEP_TEMP; then info "Fichiers temporaires dans : $tmpdir"; fi
  if ! $KEEP_TEMP; then trap 'rm -rf "$SCAN_TMPDIR"' EXIT; fi

  local source_file

  # --- Étape 1 : Source (scan ou fichier existant) --------------------------
  if [[ -n "$INPUT_FILE" ]]; then
    [[ -f "$INPUT_FILE" ]] || error "Fichier introuvable : $INPUT_FILE"
    info "Source : $INPUT_FILE"

    if [[ "$INPUT_FILE" == *.pdf ]] || [[ "$INPUT_FILE" == *.PDF ]]; then
      info "Conversion PDF → PNM (${RESOLUTION} dpi, ${DEPTH}-bit)..."
      convert -density "$RESOLUTION" -depth "$DEPTH" "$INPUT_FILE" "${tmpdir}/source.pnm" \
        || error "Échec de la conversion PDF"
      source_file="${tmpdir}/source.pnm"
    else
      source_file="$INPUT_FILE"
    fi

  elif $MULTI_PAGE; then
    MERGED_PDF=""; MULTI_PAGE_FILES=()
    do_multi_page "$tmpdir"
    if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
      local base="${OUTPUT%.jpg}"
      local total="${#MULTI_PAGE_FILES[@]}"
      local idx=1
      for f in "${MULTI_PAGE_FILES[@]}"; do
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
    else
      local pre_ocr
      if $OCR; then
        pre_ocr="${tmpdir}/pre_ocr.pdf"
        if $COMPRESS; then
          do_compress "$MERGED_PDF" "$pre_ocr"
        else
          cp "$MERGED_PDF" "$pre_ocr"
        fi
        do_ocr "$pre_ocr" "$OUTPUT"
      elif $COMPRESS; then
        do_compress "$MERGED_PDF" "$OUTPUT"
      else
        cp "$MERGED_PDF" "$OUTPUT"
      fi
      if [[ "$STRIP_META" != "false" ]]; then
        local pre_strip_mp="${tmpdir}/pre_strip_mp.pdf"
        mv "$OUTPUT" "$pre_strip_mp"
        do_strip_meta "$pre_strip_mp" "$OUTPUT"
      fi
      _print_done
    fi
    return

  else
    source_file="${tmpdir}/scan_raw.pnm"
    do_scan "$source_file"
  fi

  # --- Étape 2 : Post-traitement --------------------------------------------
  local processed_out="${tmpdir}/processed.${ext}"
  do_process "$source_file" "$processed_out"

  # --- Étape 3 : Finalisation -----------------------------------------------
  if [[ "$OUTPUT_FORMAT" == "jpeg" ]]; then
    cp "$processed_out" "$OUTPUT"
    if [[ "$STRIP_META" != "false" ]]; then
      local stripped_jpg="${tmpdir}/stripped.jpg"
      do_strip_meta "$OUTPUT" "$stripped_jpg"
      mv "$stripped_jpg" "$OUTPUT"
    fi
  elif $OCR; then
    local pre_ocr="${tmpdir}/pre_ocr.pdf"
    if $COMPRESS; then
      do_compress "$processed_out" "$pre_ocr"
    else
      cp "$processed_out" "$pre_ocr"
    fi
    do_ocr "$pre_ocr" "$OUTPUT"
  elif $COMPRESS; then
    do_compress "$processed_out" "$OUTPUT"
  else
    cp "$processed_out" "$OUTPUT"
  fi

  if [[ "$OUTPUT_FORMAT" == "pdf" ]] && [[ "$STRIP_META" != "false" ]]; then
    local pre_strip="${tmpdir}/pre_strip.pdf"
    mv "$OUTPUT" "$pre_strip"
    do_strip_meta "$pre_strip" "$OUTPUT"
  fi

  _print_done
}

_print_done() {
  local final_size
  final_size=$(du -sh "$OUTPUT" | cut -f1)
  echo ""
  echo -e "${GREEN}${BOLD}✓ Terminé !${RESET}"
  echo -e "  Fichier : ${BOLD}${OUTPUT}${RESET}  (${final_size})"
  echo ""
}

# =============================================================================
#  POINT D'ENTRÉE
# =============================================================================

if [[ $# -eq 0 ]]; then
  # Aucun argument → mode interactif avec menus guidés
  run_interactive
else
  # Arguments CLI → mode direct (comportement d'origine)
  check_deps
  main_process
fi