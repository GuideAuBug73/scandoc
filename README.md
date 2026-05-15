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
- **Multi-page scan** — fixed page count or continuous mode (page by page until manually stopped)
- **PDF or JPEG output**
- **PDF compression** — via Ghostscript (preset selected automatically based on resolution)
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
sudo apt install libimage-exiftool-perl        # Full metadata removal
```

| Package | Role |
|---|---|
| `ocrmypdf` | Adds an invisible text layer to the PDF |
| `tesseract-ocr-fra` | French language data for Tesseract OCR |
| `libimage-exiftool-perl` | Removes metadata residues left by Ghostscript |

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

1. Choose action (single scan / existing file / multi-page / list scanners)
2. Select scanner (auto-detect or enter manually)
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
| `-n <nb>` | Number of pages (multi-page mode) | `1` |
| `-R` | Enable OCR | — |
| `-L <lang>` | OCR language (`fra`, `eng`, `fra+eng`…) | `fra+eng` |
| `-M` | Strip all metadata | — |
| `-t <0-100>` | Binarisation threshold (mode `bw`) | `55` |
| `-w <0-100>` | Whitening threshold (mode `clean`) | `75` |
| `-b <0-3>` | Noise-reduction blur radius before binarisation | `0` |
| `-C` | Disable Ghostscript compression | — |
| `-k` | Keep temporary files (debug) | — |
| `-l` | List available scanners | — |
| `-h` | Show help | — |

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

> **PDF note**: Ghostscript always re-injects its own `Producer` field. Install `libimage-exiftool-perl` for complete removal.

---

## Scanner Compatibility

The script uses SANE (`scanimage`) and is compatible with all SANE-supported scanners on Linux: Brother, Epson, Canon, HP, Fujitsu, Plustek, etc.

To find your scanner's device ID:
```bash
./scandoc.sh -l
# or
scanimage -L
```

Tested backends: `dsseries` (Brother DS-720D). The options used (`--mode`, `--resolution`, `-x`, `-y`, `--format=pnm`) are standard and supported by the vast majority of modern backends.

---

## License

MIT
