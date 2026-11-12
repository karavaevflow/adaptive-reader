#!/usr/bin/env python3
"""Deterministic, project-authored EPUB corpus. Run from the repository root."""
from pathlib import Path
import zipfile

root = Path("Research/Fixtures/EPUB")
root.mkdir(parents=True, exist_ok=True)
container = '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
package = '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">adaptive-study-specimen</dc:identifier><dc:title>Adaptive EPUB Specimen</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-12T00:00:00Z</meta></metadata>
<manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="image" href="diagram.svg" media-type="image/svg+xml"/></manifest>
<spine><itemref idref="one"/><itemref idref="two"/></spine></package>'''
def xhtml(body):
    return '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Reading and memory</title></head><body>' + body + '</body></html>'
one = xhtml('''<h1>Reading and memory</h1><p>Learning begins with attention. A stable source anchor survives a change of typeface and column width.</p><p>Понимание начинается с внимания. Закладка возвращает к тому же фрагменту текста.</p><figure><img src="diagram.svg" alt="A blue circle connected to a green square"/><figcaption>Figure 1. Attention connects reading to recall.</figcaption></figure><p>A footnote opens through the reader command history.<a epub:type="noteref" href="two.xhtml#note">[1]</a></p><p><a href="two.xhtml">Continue to the long chapter</a></p>''')
two = xhtml('<h1>A long chapter</h1>' + ''.join(f'<p id="p{i}">Passage {i}. Retrieval practice strengthens memory through active recall. Reflow changes presentation while keeping the original text and its source locator stable. Images preserve their colors.</p>' for i in range(1800)) + '<aside id="note" epub:type="footnote"><p>Footnote one: reading positions belong to the source, independently of layout.</p><a href="one.xhtml">Return to chapter one</a></aside>')
files = {"mimetype": "application/epub+zip", "META-INF/container.xml": container, "EPUB/package.opf": package, "EPUB/one.xhtml": one, "EPUB/two.xhtml": two, "EPUB/nav.xhtml": xhtml('<nav epub:type="toc"><ol><li><a href="one.xhtml">Reading and memory</a></li><li><a href="two.xhtml">A long chapter</a></li></ol></nav>'), "EPUB/diagram.svg": '<svg xmlns="http://www.w3.org/2000/svg" width="360" height="100" viewBox="0 0 360 100"><circle cx="55" cy="50" r="30" fill="#2080df"/><path d="M85 50H260" stroke="#888" stroke-width="2"/><rect x="260" y="20" width="60" height="60" fill="#308b60"/></svg>'}
def write(name, entries, stored=False):
    with zipfile.ZipFile(root / name, 'w') as archive:
        for path, value in entries.items():
            info = zipfile.ZipInfo(path, (2026, 11, 12, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if path == "mimetype" or stored else zipfile.ZIP_DEFLATED
            archive.writestr(info, value)
write('reflow.epub', files)
write('image-only.epub', files | {'EPUB/one.xhtml': xhtml('<img src="diagram.svg" alt="An illustration"/>'), 'EPUB/two.xhtml': xhtml('<img src="diagram.svg" alt="Another illustration"/>')})
write('corrupt.epub', files, stored=True)
corrupt = root / 'corrupt.epub'
corrupt.write_bytes(corrupt.read_bytes().replace(b'#2080df', b'#2080de'))
write('encrypted.epub', files | {'META-INF/encryption.xml': '<encryption/>'})
write('traversal.epub', files | {'../escape.txt': 'must never extract'})
write('scripted.epub', files | {'EPUB/one.xhtml': one.replace('<body>', '<body onload="fetch(\'https://example.com\')"><script>window.authoredScriptRan=true</script><iframe src="https://example.com"/>')})
write('fixed-layout.epub', files | {'EPUB/package.opf': package.replace('</metadata>', '<meta property="rendition:layout">pre-paginated</meta></metadata>')})
write('linked-footnotes.epub', files | {
    'EPUB/package.opf': package.replace('</manifest>', '<item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest>'),
    'EPUB/notes.xhtml': xhtml('<h1>Additional notes</h1><aside id="footnote"><p>A note outside the linear reading order.</p></aside>')
})
print(root)
