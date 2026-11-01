[🇫🇷 Lire en français](README.fr.md)

# scandoc.sh — Document Scanner Assistant for Linux

A Bash script to scan documents via SANE, process them with ImageMagick and export them as compressed PDF or JPEG. Designed for everyday use, with an interactive guided mode and a command-line mode for automation.

---

## Features

- **Interactive mode** — step-by-step guided menus, no technical knowledge required
- **CLI mode** — all options available on the command line for scripting and automation
- **4 image processing modes** — grey background cleanup, pure black & white, colour normalisation, raw
- **Paper formats** — A4, A5, Letter, Legal, custom, or auto-detection with automatic cropping
- **Configurable resolution** — 150 / 300 / 600 dpi or custom value
- **Multi-page scan** — fixed page count, continuous mode (page by page until manually stopped) or automatic document feeder (ADF)
- **PDF or JPEG output**
- **PDF compression** — via Ghostscript (preset selected automatically based on resolution); black & white uses lossless CCITT Group4, much smaller
- **OCR** — selectable and copyable text layer in PDF via ocrmypdf + Tesseract
- **Metadata removal** — strip everything or everything except dates, for both PDF and JPEG
- **Automatic dependency installation** — missing packages offered for install in interactive mode
- **Process an existing file** — bypass the scanner and process an image or PDF already on disk

---

## Dependencies

### Required

```bash
sudo apt install sane-utils imagemagick ghostscript
```

| Package | Role |
|---|---|
| `sane-utils` | Scanner interface (`scanimage`) |
| `imagemagick` | Image processing, conversion, PDF assembly |
| `ghostscript` | PDF compression and optimisation |

### Optional

```bash
sudo apt install ocrmypdf tesseract-ocr-fra   # French OCR
sudo apt install libimage-exiftool-perl qpdf   # Complete, unrecoverable metadata removal
```

| Package | Role |
|---|---|
| `ocrmypdf` | Adds an invisible text layer to the PDF |
| `tesseract-ocr-fra` | French language data for Tesseract OCR |
| `libimage-exiftool-perl` | Removes metadata residues left by Ghostscript |
| `qpdf` | Rewrites the PDF so removed metadata can no longer be recovered |

> In interactive mode, the script offers to automatically install any missing packages.

---

## Installation

```bash
git clone <repo-url>
cd "Scan document linux"
chmod +x scandoc.sh
```

Optional — make it available system-wide:

```bash
sudo ln -s "$PWD/scandoc.sh" /usr/local/bin/scandoc
```

---

## Usage

### Interactive mode (recommended)

```bash
./scandoc.sh
```

The script guides you step by step:

1. Choose action (single scan / existing file / multi-page / scanner diagnostics)
2. Select scanner (auto-detect, pick from the list or enter manually)
3. Paper format
4. Resolution
5. Processing mode
6. Output format (PDF or JPEG) and filename
7. OCR (PDF only)
8. Metadata
9. Advanced options (compression, thresholds, JPEG quality…)
10. Summary and confirmation

### Command-line mode

```bash
./scandoc.sh [OPTIONS]
```

---

## CLI Options

| Option | Description | Default |
|---|---|---|
| `-r <dpi>` | Resolution (150 / 300 / 600 or custom) | `300` |
| `-m <mode>` | Processing mode (`scan` / `clean` / `bw` / `color`) | `clean` |
| `-o <file>` | Output file | `scan_YYYYMMDD_HHMMSS.pdf` |
| `-f <file>` | Existing source file (bypass scanner) | — |
| `-F <format>` | Paper format: `auto`, `A4`, `A5`, `Letter`, `Legal`, `WxH` (mm) | `auto` |
| `-O <format>` | Output format: `pdf` or `jpeg` | `pdf` |
| `-d <device>` | SANE scanner device ID | auto-detect |
| `-p` | Multi-page mode | — |
| `-n <nb>` | Number of pages (enables multi-page mode if > 1) | `1` |
| `-a` | Automatic document feeder (ADF): scan the whole tray at once | — |
| `-S <source>` | Explicit SANE source (`ADF`, `ADF Duplex`, `Flatbed`…, see `scanimage -A`) | auto-detected with `-a` |
| `-R` | Enable OCR | — |
| `-L <lang>` | OCR language (`fra`, `eng`, `fra+eng`…) | `fra+eng` |
| `-M` | Strip all metadata | — |
| `-t <0-100>` | Binarisation threshold (mode `bw`) | `55` |
| `-w <0-100>` | Whitening threshold (mode `clean`) | `75` |
| `-b <0-3>` | Noise-reduction blur radius before binarisation | `0` |
| `-C` | Disable Ghostscript compression | — |
| `-y` | Overwrite the output file if it already exists (otherwise: prompt, or error outside a terminal) | — |
| `-V` | Open the resulting file at the end (`xdg-open`) | — |
| `-k` | Keep temporary files (debug) | — |
| `-l` | List available scanners | — |
| `-D`, `--diagnostic` | Show what each scanner accepts (sources, modes, resolutions, area) | — |
| `-h` | Show help | — |

---

## Default settings

The **"Réglages par défaut"** menu (choice 5 of the main menu) saves your usual choices to `~/.config/scandoc.conf` (or `$XDG_CONFIG_HOME/scandoc.conf`, or the path in `SCANDOC_CONFIG`). They become the menu defaults and are used on the command line; command-line options still take precedence.

The file can also be written by hand, one `KEY="value"` per line (it is never executed). Keys: `DEVICE`, `SCAN_SOURCE`, `RESOLUTION`, `MODE`, `PAPER_FORMAT`, `OUTPUT_FORMAT`, `OUTPUT_DIR`, `JPEG_QUALITY`, `THRESHOLD`, `WHITE_THRESH`, `BLUR`, `COMPRESS`, `OCR`, `OCR_LANG`, `STRIP_META`, `OPEN_RESULT`.

In interactive mode, paths accept `~` and drag-and-drop from a file manager (quotes, `file://`).

---

## Examples

```bash
# Simple scan with default settings
./scandoc.sh -o invoice.pdf

# High-resolution colour scan
./scandoc.sh -r 600 -m color -o photo.pdf

# Process an existing file in black and white
./scandoc.sh -f raw_scan.jpg -m bw -t 60 -o result.pdf

# Scan 5 pages assembled into a single PDF
./scandoc.sh -p -n 5 -o document.pdf

# Every page in the automatic document feeder, black & white
./scandoc.sh -a -m bw -o letter.pdf

# PDF with French OCR and metadata stripped
./scandoc.sh -R -L fra -M -o document_ocr.pdf

# Explicit A4 format, compression disabled
./scandoc.sh -F A4 -C -o original.pdf

# List available scanners
./scandoc.sh -l
```

---

## Processing Modes

| Mode | Best for | Description |
|---|---|---|
| `clean` | Letters, invoices, contracts | Whitens grey background, preserves colours |
| `bw` | Forms, receipts, plain text | Pure black and white, very small file size |
| `color` | Photos, plans, colour documents | Colour normalisation and saturation boost |
| `scan` | Raw archiving | No processing, PDF straight from the scanner |

---

## OCR — Selectable Text

When OCR is enabled, the final PDF contains an invisible text layer overlaid on the image. The text becomes:
- copy-pasteable
- searchable with Ctrl+F
- readable by screen readers

Processing is non-destructive: `--skip-text` skips pages that already contain text. If OCR fails, the image PDF is preserved without a fatal error.

**Available languages** (ISO 639-2 codes): `fra`, `eng`, `deu`, `spa`, `ita`… Multiple languages separated by `+`: `fra+eng`.

To install an additional language:
```bash
sudo apt install tesseract-ocr-<code>   # e.g. tesseract-ocr-deu
```

---

## Metadata

PDF and JPEG files produced by the script contain metadata by default, revealing the tools used (ImageMagick, Ghostscript, OCRmyPDF…). Three options are available:

| Mode | Behaviour |
|---|---|
| **Keep** *(default)* | Original metadata preserved |
| **Strip except dates** | Clears tool/author fields, keeps CreationDate and ModDate |
| **Strip all** | No metadata |

> **PDF note**: Ghostscript always re-injects its own `Producer` field, and exiftool edits PDFs reversibly (old values stay in the file). Install `libimage-exiftool-perl` and `qpdf`: exiftool clears the fields, then qpdf rewrites the file so nothing is recoverable.

---

## Scanner Compatibility

The script goes through SANE (`scanimage`): it works with every scanner SANE supports on Linux (Brother, Epson, Canon, HP, Fujitsu, Plustek…), including most network or recent scanners without a driver thanks to [`sane-airscan`](https://github.com/alexpevzner/sane-airscan) (`sudo apt install sane-airscan`).

Each driver names its settings its own way. Before scanning, the script reads the scanner's options once (`scanimage -A`) and adapts:

- **Color mode**: the name the driver expects is picked automatically (`Color`, `Colour`, `24bit Color`… / `Gray`, `Grayscale`, `True Gray`…).
- **Resolution**: rounded to the nearest accepted value (e.g. 250 dpi → 300 dpi if the scanner only offers 200 and 300).
- **Paper format**: limited to the scanner's maximum area (e.g. Legal on an A4 flatbed).
- **Feeder (`-a`)**: the "ADF" / "Feeder" source is found among the scanner's sources.
- **Several scanners**: in interactive mode the script asks which one to use; on the command line it takes the first and shows how to pick another with `-d`. Webcams are ignored.

Each adjustment is reported with a warning. If the scanner's options cannot be read, the standard settings (`Color`/`Gray`) are used.

To see detected scanners and what each one accepts:
```bash
./scandoc.sh -l            # quick list
./scandoc.sh --diagnostic  # details: sources, modes, resolutions, maximum area
```

Some manufacturers' proprietary drivers (Brother `brscan`, Epson Image Scan…) must be installed separately, from the manufacturer's website.

Tested backends: `dsseries` (Brother DS-720D).

---

## License

MIT
