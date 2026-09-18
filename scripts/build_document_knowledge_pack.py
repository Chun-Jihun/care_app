"""Extract local originals into an offline, unreviewed document preview pack."""
from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.knowledge_pack import PackError, PackWriter, sha
from scripts.mfds_snapshot import file_digest


class ArticleParser(HTMLParser):
    """Read saved main content. Never execute HTML or fetch external resources."""

    ignored = {"script", "style", "nav", "footer", "form", "button", "iframe", "noscript"}
    void = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
    breaks = {"p", "div", "section", "article", "h1", "h2", "h3", "h4", "li", "tr", "br"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.parts = []
        self.images = []
        self.found_main = False

    @property
    def active(self):
        return "main" in self.stack and not any(t in self.ignored for t in self.stack)

    def handle_starttag(self, tag, attrs):
        if tag not in self.void:
            self.stack.append(tag)
        if tag == "main":
            self.found_main = True
        if not self.active:
            return
        if tag in self.breaks:
            self.parts.append("\n")
        if tag in ("td", "th"):
            self.parts.append(" | ")
        if tag == "img":
            attr = dict(attrs)
            if attr.get("src"):
                self.images.append((attr["src"], attr.get("alt", "")))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if self.active and tag in self.breaks:
            self.parts.append("\n")
        if tag in self.stack:
            del self.stack[len(self.stack) - 1 - self.stack[::-1].index(tag):]

    def handle_data(self, data):
        if self.active:
            self.parts.append(re.sub(r"\s+", " ", data))

    def text(self):
        result = "\n".join(line.strip() for line in "".join(self.parts).splitlines() if line.strip())
        if not self.found_main or not result:
            raise PackError("Saved HTML has no readable main content")
        return result


def local_asset(document: Path, reference: str) -> Path:
    parsed = urlsplit(reference)
    if parsed.scheme or parsed.netloc or parsed.query:
        raise PackError("Remote/embedded HTML assets need explicit offline preparation")
    base = document.parent.resolve()
    candidate = (base / unquote(parsed.path)).resolve()
    if not candidate.is_relative_to(base) or not candidate.is_file():
        raise PackError("Missing or out-of-directory HTML image")
    return candidate


def lossless_webp(path: Path) -> bytes:
    from PIL import Image
    with Image.open(path) as original:
        raster = original.convert("RGBA" if "A" in original.getbands() else "RGB")
        buffer = io.BytesIO()
        raster.save(buffer, "WEBP", lossless=True, exact=True, method=4)
        raw = buffer.getvalue()
        with Image.open(io.BytesIO(raw)) as restored:
            if restored.convert(raster.mode).tobytes() != raster.tobytes():
                raise PackError("Page image pixel roundtrip failed")
    return raw


def add_page(writer, source, number, text, image=None):
    raw = text.encode("utf-8")
    page_id = writer.db.execute(
        "INSERT INTO document_pages(source_id,page_no,label,text_blob,image_blob,text_sha256) VALUES (?,?,?,?,?,?)",
        (source, number, str(number), writer.add_blob(raw), writer.add_blob(image) if image else None, sha(raw)),
    ).lastrowid
    writer.db.execute("INSERT INTO document_search(rowid,text) VALUES (?,?)", (page_id, text))
    writer.stats["pages"] += 1
    return page_id


def build(inventory: Path, output: Path, project: Path, renderer: Path, dpi=144):
    if not 120 <= dpi <= 180:
        raise PackError("Review page resolution must be between 120 and 180 DPI")
    inventory_bytes = inventory.read_bytes()
    data = json.loads(inventory_bytes)
    if data.get("approval_state") != "staged_unreviewed" or data.get("runtime_rag_eligible") is not False:
        raise PackError("Unexpected inventory approval state")
    writer = PackWriter(output, "documents")
    try:
        for entry in data["documents"]:
            path = (project / entry["path"]).resolve()
            if not path.is_relative_to(project.resolve()) or file_digest(path) != entry["sha256"]:
                raise PackError("Original document path or checksum mismatch")
            source = entry["sha256"]
            metadata = {**entry, "title": entry.get("embedded_title") or path.stem,
                        "url": entry["source_url"], "source_sha256": source,
                        "extraction_review_status": "pending", "raster_dpi": dpi if path.suffix.lower() == ".pdf" else None,
                        "page_image_format": "webp_lossless", "page_numbering": "physical_1_based"}
            writer.source(source, metadata)
            writer.stats["input_bytes"] += path.stat().st_size
            if path.suffix.lower() == ".pdf":
                from pypdf import PdfReader
                reader = PdfReader(path)
                if len(reader.pages) != entry["page_count"]:
                    raise PackError("PDF page count changed")
                with tempfile.TemporaryDirectory(prefix="care-pages-") as temporary:
                    prefix = Path(temporary) / "page"
                    # One page at a time bounds temporary disk and memory usage.
                    for number, page in enumerate(reader.pages, 1):
                        subprocess.run([str(renderer), "-f", str(number), "-l", str(number),
                                        "-singlefile", "-r", str(dpi), "-png", str(path), str(prefix)],
                                       check=True, capture_output=True, timeout=120)
                        add_page(writer, source, number, page.extract_text() or "", lossless_webp(prefix.with_suffix(".png")))
                        if number % 25 == 0:
                            writer.db.commit()
                            print(f"{path.name}: {number}/{len(reader.pages)} pages verified", flush=True)
            elif path.suffix.lower() == ".html":
                article = ArticleParser()
                article.feed(path.read_text(encoding="utf-8-sig"))
                page_id = add_page(writer, source, 1, article.text())
                for ordinal, (reference, alt) in enumerate(dict.fromkeys(article.images), 1):
                    asset = local_asset(path, reference)
                    blob = writer.add_blob(lossless_webp(asset))
                    writer.db.execute("INSERT INTO page_assets VALUES (?,?,?,?)", (page_id, ordinal, blob, alt))
                    writer.stats["assets"] += 1
            else:
                raise PackError("Unsupported original format")
            writer.db.commit()
            print(f"{path.name}: complete", flush=True)
        return writer.finish({"inventory_sha256": sha(inventory_bytes), "document_count": len(data["documents"]),
                              "image_pixels_verified": True, "text_extraction_reviewed": False})
    finally:
        writer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=Path("docs/medical_reference_inventory.json"))
    parser.add_argument("--project", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pdftoppm", type=Path, required=True)
    parser.add_argument("--dpi", type=int, default=144)
    args = parser.parse_args()
    print(json.dumps(build(args.inventory, args.output, args.project, args.pdftoppm, args.dpi), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
